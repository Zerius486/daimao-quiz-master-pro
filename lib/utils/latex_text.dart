import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// LaTeX 文本切分片段（普通文本 / 行内公式 / 块级公式）。
sealed class LatexSegment {
  const LatexSegment();
}

class LatexTextRun extends LatexSegment {
  final String text;
  const LatexTextRun(this.text);
}

class LatexMathRun extends LatexSegment {
  final String tex;
  final String raw;
  final bool display;
  const LatexMathRun({
    required this.tex,
    required this.raw,
    required this.display,
  });
}

/// 快速检测是否可能包含 LaTeX 定界符（无定界符时走零开销直通）。
bool mightContainLatex(String text) =>
    text.contains(r'$') || text.contains(r'\(') || text.contains(r'\[');

final RegExp _latexTokenRe = RegExp(
  r'\$\$([\s\S]+?)\$\$' // $$...$$ 块级
  r'|\\\[([\s\S]+?)\\\]' // \[...\] 块级
  r'|\\\(([\s\S]+?)\\\)' // \(...\) 行内
  r'|\$([^\$\n]+?)\$', // $...$ 行内（不跨行）
);

/// 将文本切分为普通文本与 LaTeX 公式片段；未闭合的定界符原样保留。
List<LatexSegment> splitLatexSegments(String text) {
  if (!mightContainLatex(text)) return [LatexTextRun(text)];

  final out = <LatexSegment>[];
  var cursor = 0;
  for (final m in _latexTokenRe.allMatches(text)) {
    // 跳过被反斜杠转义的 \$（如 \$100）
    if (m.group(0)!.startsWith(r'$') &&
        !m.group(0)!.startsWith(r'$$') &&
        m.start > 0 &&
        text.codeUnitAt(m.start - 1) == 0x5C) {
      continue;
    }
    if (m.start > cursor) {
      out.add(LatexTextRun(text.substring(cursor, m.start)));
    }
    final displayTex = m.group(1) ?? m.group(2);
    final inlineTex = m.group(3) ?? m.group(4);
    final tex = (displayTex ?? inlineTex ?? '').trim();
    if (tex.isEmpty) {
      out.add(LatexTextRun(m.group(0)!));
    } else {
      out.add(LatexMathRun(
        tex: tex,
        raw: m.group(0)!,
        display: displayTex != null,
      ));
    }
    cursor = m.end;
  }
  if (cursor < text.length) {
    out.add(LatexTextRun(text.substring(cursor)));
  }
  return out.isEmpty ? [LatexTextRun(text)] : out;
}

/// 构造单个 LaTeX 公式 Widget（解析失败时优雅降级为原始文本）。
Widget buildLatexMathWidget(
  String tex, {
  required String fallbackText,
  TextStyle? style,
  bool display = false,
}) {
  final math = Math.tex(
    tex,
    textStyle: style,
    mathStyle: display ? MathStyle.display : MathStyle.text,
    onErrorFallback: (_) => Text(fallbackText, style: style),
  );
  if (!display) return math;
  return SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: math,
  );
}

/// 将含 LaTeX 公式的文本转为可嵌入 [Text.rich] 的 [InlineSpan] 列表。
List<InlineSpan> buildLatexInlineSpans(String text, {TextStyle? style}) {
  final segments = splitLatexSegments(text);
  return [
    for (final seg in segments)
      if (seg is LatexTextRun)
        TextSpan(text: seg.text)
      else if (seg is LatexMathRun)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: buildLatexMathWidget(
              seg.tex,
              fallbackText: seg.raw,
              style: style,
              display: seg.display,
            ),
          ),
        ),
  ];
}
