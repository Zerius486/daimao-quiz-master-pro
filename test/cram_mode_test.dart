import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flashcard_app/models/question.dart';
import 'package:flashcard_app/models/question_bank.dart';
import 'package:flashcard_app/screens/quiz_screen.dart';
import 'package:flashcard_app/services/app_state.dart';
import 'package:flashcard_app/services/bank_file_service.dart';
import 'package:flashcard_app/services/database_service.dart';
import 'package:flashcard_app/services/quiz_service.dart';
import 'package:flashcard_app/services/theme_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('QuizService 当轮闭环突击队列', () {
    List<Question> makeQs(int n) => [
          for (var i = 1; i <= n; i++)
            Question(
              id: i,
              bankId: 1,
              title: '第 $i 题',
              correctAnswer: '答案 $i',
              questionType: 'jian_da',
              createdAt: '2026-01-01T00:00:00Z',
            ),
        ];

    test('不会(offset=4)插回后方，模糊(null)放轮末，稳了直接推进', () {
      final qs = makeQs(6);
      final svc = QuizService()
        ..startCustomSession(questions: qs, bankIds: [1], mode: 'cram');

      expect(svc.currentQuestion!.id, 1);
      // 第 1 题点「不会」→ 插回 index 4
      svc.requeueCurrentQuestion(offsetFromCurrent: 4);
      expect(svc.totalQuestions, 7);
      expect(svc.questions[4].id, 1);

      expect(svc.nextQuestion(), isTrue);
      expect(svc.currentQuestion!.id, 2);

      // 第 2 题点「模糊」→ 放轮末
      svc.requeueCurrentQuestion();
      expect(svc.totalQuestions, 8);
      expect(svc.questions.last.id, 2);
    });
  });

  group('DatabaseService v13 期末突击状态与知识点清零', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('mj_cram_db_');
      await DatabaseService.instance.close();
      DatabaseService.overrideDbPath = '${tmpDir.path}/test.db';
    });

    tearDown(() async {
      await DatabaseService.instance.close();
      DatabaseService.overrideDbPath = null;
      await tmpDir.delete(recursive: true);
    });

    test('按知识点聚合突击进度并支持重置，不污染 FSRS', () async {
      final db = DatabaseService.instance;
      final bankId = await db.insertBank(QuestionBank(
        name: '思政期末',
        createdAt: '2026-01-01T00:00:00Z',
      ));
      final ids = await db.insertQuestions([
        Question(
          bankId: bankId,
          title: 'Q1',
          correctAnswer: 'A1',
          questionType: 'jian_da',
          knowledgePoint: '第一章',
          createdAt: '2026-01-01T00:00:00Z',
        ),
        Question(
          bankId: bankId,
          title: 'Q2',
          correctAnswer: 'A2',
          questionType: 'jian_da',
          knowledgePoint: '第一章',
          createdAt: '2026-01-01T00:00:00Z',
        ),
        Question(
          bankId: bankId,
          title: 'Q3',
          correctAnswer: 'A3',
          questionType: 'jie_da',
          knowledgePoint: '第二章',
          createdAt: '2026-01-01T00:00:00Z',
        ),
      ]);

      await db.setCramStatus(ids[0], 'mastered');
      await db.setCramStatus(ids[1], 'again');

      final progress = await db.getCramProgressByKnowledgePoint([bankId]);
      expect(progress.length, 2);
      final ch1 = progress.firstWhere((e) => e.kp == '第一章');
      expect(ch1.total, 2);
      expect(ch1.mastered, 1);
      expect(ch1.needReview, 1);

      await db.resetCramStatuses([bankId]);
      final afterReset = await db.getCramStatusesByBank([bankId]);
      expect(afterReset, isEmpty);
    });
  });

  group('无键盘主观题与大题自评交互', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('mj_cram_ui_');
      await DatabaseService.instance.close();
      DatabaseService.overrideDbPath = '${tmpDir.path}/test.db';
    });

    tearDown(() async {
      await DatabaseService.instance.close();
      DatabaseService.overrideDbPath = null;
      await tmpDir.delete(recursive: true);
    });

    testWidgets('背题/大题默认无 TextField，点击出解析后出现不会/模糊/稳了自评',
        (tester) async {
      final appState = AppState();
      await tester.runAsync(() async {
        final db = DatabaseService.instance;
        final bankId = await db.insertBank(QuestionBank(
          name: '高数大题',
          createdAt: '2026-01-01T00:00:00Z',
        ));
        await db.insertQuestions([
          Question(
            bankId: bankId,
            title: '求函数 f(x)=x^2 的导数。',
            correctAnswer: "f'(x)=2x",
            analysis: '幂函数求导法则。',
            questionType: 'jie_da',
            knowledgePoint: '导数',
            createdAt: '2026-01-01T00:00:00Z',
          ),
        ]);
        appState.toggleBankSelection(bankId);
        await appState.startQuiz(persistSession: false);
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: appState),
            ChangeNotifierProvider<ThemeService>.value(value: ThemeService()),
          ],
          child: MaterialApp(
            theme: ThemeService().themeData,
            home: const QuizScreen(quizMode: QuizMode.normal),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 默认不弹键盘（无 TextField）
      expect(find.byType(TextField), findsNothing);
      expect(find.text('写完了，查看答案与解析'), findsOneWidget);

      await tester.tap(find.text('写完了，查看答案与解析'));
      await tester.pumpAndSettle();

      expect(find.text('参考答案'), findsOneWidget);
      expect(find.text('不会'), findsOneWidget);
      expect(find.text('模糊'), findsOneWidget);
      expect(find.text('稳了'), findsOneWidget);
    });
  });

  group('JSON 题库模板解析', () {
    test('BankFileService 正确解析 recite 背题与 jie_da 大题并保留原文答案', () async {
      final f = File(
          '/home/zerius/Documents/maojuan_templates/maojuan_all_types_template.json');
      final (groups, err) = await BankFileService.parseJsonFile(f.path);
      expect(err, isNull);
      final qs = groups.values.first;
      expect(qs.length, 8);
      final recite = qs.firstWhere((q) => q.questionType == 'recite');
      expect(recite.typeLabel, '背题');
      expect(recite.correctAnswer, contains('，'));
    });
  });
}
