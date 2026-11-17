import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:flashcard_app/models/app_settings.dart';
import 'package:flashcard_app/services/ai_service.dart';
import 'package:flashcard_app/services/api_endpoint.dart';
import 'package:flashcard_app/services/doc_parser_service.dart';

void main() {
  group('Google Gemini 原生协议支持', () {
    test('端点识别：区分原生 Gemini 与 /openai 兼容路径', () {
      expect(
          ApiEndpoint.isGeminiNative(
              'https://generativelanguage.googleapis.com/v1beta'),
          isTrue);
      expect(
          ApiEndpoint.isGeminiNative(
              'https://generativelanguage.googleapis.com/v1beta/openai'),
          isFalse);
      expect(ApiEndpoint.isGeminiNative('https://api.deepseek.com/v1'), isFalse);
    });

    test('URI 构造：自动去 models/ 前缀与切换流式参数', () {
      expect(
        ApiEndpoint.geminiGenerateUri(
          'https://generativelanguage.googleapis.com/v1beta',
          'models/gemini-2.5-flash',
        ).toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent',
      );
      expect(
        ApiEndpoint.geminiGenerateUri(
          'https://generativelanguage.googleapis.com/v1beta',
          'gemini-2.5-flash',
          stream: true,
        ).toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse',
      );
      expect(
        ApiEndpoint.geminiModelsUri(
                'https://generativelanguage.googleapis.com/v1beta')
            .toString(),
        'https://generativelanguage.googleapis.com/v1beta/models',
      );
    });

    test('AIService 使用 Gemini 原生协议切题、过滤 thought 并统计 token', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'internal reasoning', 'thought': true},
                    {
                      'text': jsonEncode({
                        'questions': [
                          {
                            'title': '1+1=?',
                            'type': 'single',
                            'options': ['1', '2'],
                            'correctAnswer': 'B',
                            'analysis': '1+1=2',
                            'knowledgePoint': '算术',
                          }
                        ]
                      })
                    }
                  ]
                }
              }
            ],
            'usageMetadata': {'totalTokenCount': 123},
          })),
          200,
        );
      });

      final settings = AppSettings(
        apiKey: 'AIza-test-key',
        apiEndpoint: 'https://generativelanguage.googleapis.com/v1beta',
        model: 'gemini-2.5-flash',
      );
      final svc = AIService(settings, client: client);
      final res = await svc.parseQuestionsFromRawText('1. 1+1=?\n答案：2', 0, null);

      expect(captured.url.toString(),
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent');
      expect(captured.headers['x-goog-api-key'], 'AIza-test-key');
      final reqBody = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(reqBody['generationConfig']['responseMimeType'], 'application/json');
      expect(res.questions.length, 1);
      expect(res.questions.first.title, '1+1=?');
      expect(svc.totalTokensUsed, 123);
    });

    test('fetchModels 与 testConnection 适配 Gemini 原生接口', () async {
      final client = MockClient((req) async {
        if (req.method == 'GET') {
          return http.Response(
            jsonEncode({
              'models': [
                {
                  'name': 'models/gemini-2.5-flash',
                  'supportedGenerationMethods': ['generateContent']
                },
                {
                  'name': 'models/text-embedding-004',
                  'supportedGenerationMethods': ['embedContent']
                },
              ]
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'hi'}
                  ]
                }
              }
            ]
          }),
          200,
        );
      });

      final svc = AIService(
        AppSettings(
          apiKey: 'AIza-test-key',
          apiEndpoint: 'https://generativelanguage.googleapis.com/v1beta',
          model: 'gemini-2.5-flash',
        ),
        client: client,
      );
      final (models, err) = await svc.fetchModels();
      expect(err, isNull);
      expect(models, ['gemini-2.5-flash']);

      final (ok, msg) = await svc.testConnection();
      expect(ok, isTrue, reason: msg);
    });

    test('Gemini SSE 行解析 delta 与 usageMetadata', () {
      const line =
          'data: {"candidates":[{"content":{"parts":[{"text":"你好"}]}}],"usageMetadata":{"totalTokenCount":42}}';
      expect(AIService.deltaFromSseLine(line), '你好');
      expect(AIService.usageFromSseLine(line), 42);
    });
  });

  group('输入优化：预清洗、切块与失败重试', () {
    test('cleanRawTextForParsing 清理装饰分隔线与多余空行并保留 {{img:N}}', () {
      const raw = '第一行   \r\n=====\r\n\r\n\r\n第二行 {{img:1}}\n-----\n';
      expect(
        AIService.cleanRawTextForParsing(raw),
        '第一行\n\n第二行 {{img:1}}',
      );
    });

    test('questionStartPattern 兼容 Q1. 与 [1] 题号变体', () {
      expect(AIService.isQuestionStart('Q1. 题干内容'), isTrue);
      expect(AIService.isQuestionStart('[12] 题干内容'), isTrue);
    });

    test('retryFailedChunks 仅重跑失败块并保留原块号', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'questions': [
                      {
                        'title': '重试成功的题',
                        'type': 'single',
                        'options': ['A', 'B'],
                        'correctAnswer': 'A',
                        'analysis': 'ok',
                        'knowledgePoint': '基础',
                      }
                    ]
                  })
                }
              }
            ]
          })),
          200,
        );
      });

      final svc = AIService(
        AppSettings(apiKey: 'k', apiEndpoint: 'https://api.deepseek.com/v1'),
        client: client,
      );
      final retryRes = await svc.retryFailedChunks(
        const [
          AIParseChunkFailure(index: 2, rawChunk: '3. 重试成功的题', error: '超时'),
        ],
        0,
        null,
      );
      expect(calls, 1);
      expect(retryRes.failedChunks, 0);
      expect(retryRes.questions.length, 1);
      expect(retryRes.questions.first.title, '重试成功的题');
    });
  });

  group('DOCX 配图提取与 TXT/MD 读取', () {
    test('extractPlainText 去除 UTF-8 BOM', () async {
      final dir = await Directory.systemTemp.createTemp('mj_txt_');
      try {
        final f = File('${dir.path}/sample.md');
        await f.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode('1. 测试题目')]);
        expect(await DocParserService.extractPlainText(f.path), '1. 测试题目');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('extractDocxWithImages 提取 word/media 图片并生成 {{img:1}}', () async {
      final dir = await Directory.systemTemp.createTemp('mj_docx_');
      try {
        final png = Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));
        const docXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <w:body>
    <w:p><w:r><w:t>1. 如下图所示，正确的选项是？</w:t></w:r></w:p>
    <w:p><w:r><w:drawing><a:blip r:embed="rId1"/></w:drawing></w:r></w:p>
  </w:body>
</w:document>''';
        const relsXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
</Relationships>''';

        final archive = Archive()
          ..addFile(ArchiveFile('word/document.xml', utf8.encode(docXml).length,
              utf8.encode(docXml)))
          ..addFile(ArchiveFile('word/_rels/document.xml.rels',
              utf8.encode(relsXml).length, utf8.encode(relsXml)))
          ..addFile(ArchiveFile('word/media/image1.png', png.length, png));

        final docxPath = '${dir.path}/test.docx';
        await File(docxPath).writeAsBytes(ZipEncoder().encode(archive)!);

        final res = await DocParserService.extractDocxWithImages(docxPath);
        expect(res.rawText, contains('1. 如下图所示，正确的选项是？'));
        expect(res.rawText, contains('{{img:1}}'));
        expect(res.imagePool.length, 1);
        expect(res.imagePool[1]!.mime, 'image/jpeg');
        expect(res.imagePool[1]!.width, 4);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
