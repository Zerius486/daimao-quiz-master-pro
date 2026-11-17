import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flashcard_app/utils/latex_text.dart';
import 'package:flashcard_app/widgets/ai_response_widget.dart';
import 'package:flashcard_app/widgets/kit/mj_rich_question_text.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(body: child),
      );

  group('LaTeX 切分解析', () {
    test('无定界符纯文本直通', () {
      final segs = splitLatexSegments('普通题目文本');
      expect(segs.length, 1);
      expect((segs.first as LatexTextRun).text, '普通题目文本');
    });

    test('识别行内 \$...\$、\\(...\\) 与块级 \$\$...\$\$、\\[...\\]', () {
      final segs = splitLatexSegments(
          r'已知 $a^2+b^2=c^2$ 与 \(E=mc^2\)，则 $$\int_0^1 x\,dx$$ 和 \[\frac{1}{2}\]');
      final maths = segs.whereType<LatexMathRun>().toList();
      expect(maths.length, 4);
      expect(maths[0].tex, 'a^2+b^2=c^2');
      expect(maths[0].display, isFalse);
      expect(maths[1].tex, 'E=mc^2');
      expect(maths[1].display, isFalse);
      expect(maths[2].tex, r'\int_0^1 x\,dx');
      expect(maths[2].display, isTrue);
      expect(maths[3].tex, r'\frac{1}{2}');
      expect(maths[3].display, isTrue);
    });

    test('转义 \\\$100 与未闭合 \$ 不误识别为公式', () {
      final escaped = splitLatexSegments(r'价格为 \$100 和 \$200');
      expect(escaped.whereType<LatexMathRun>(), isEmpty);

      final single = splitLatexSegments('单价 \$100 元');
      expect(single.whereType<LatexMathRun>(), isEmpty);
    });
  });

  group('LaTeX Widget 渲染', () {
    testWidgets('MjRichQuestionText 渲染行内 LaTeX 公式', (tester) async {
      await tester.pumpWidget(wrap(
        const MjRichQuestionText(text: r'求极限 $\lim_{x \to 0} \frac{\sin x}{x}$'),
      ));
      expect(find.byType(Math), findsOneWidget);
    });

    testWidgets('AiResponseWidget 混排 Markdown 关键词与行内/块级公式', (tester) async {
      await tester.pumpWidget(wrap(
        const AiResponseWidget(
          text: r'**结论：** ==勾股定理== $a^2+b^2=c^2$' '\n\n' r'$$\frac{1}{2}$$',
        ),
      ));
      expect(find.byType(Math), findsNWidgets(2));
    });

    testWidgets('非法 LaTeX 语法优雅降级为原始文本而不崩溃', (tester) async {
      await tester.pumpWidget(wrap(
        const MjRichQuestionText(text: r'坏公式 $\not_closed_brace{$'),
      ));
      expect(tester.takeException(), isNull);
    });
  });
}
