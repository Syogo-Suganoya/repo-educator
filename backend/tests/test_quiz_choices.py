"""選択肢の並びに関する検査。

生成AIも手書きのサンプルも、放っておくと正解を選択肢の先頭に書いてしまう。
「1番目を選べば当たる」状態に戻っていないことを、ここで押さえる。
"""

from collections import Counter

from app.sample_quizzes import SAMPLE_REPOSITORIES
from app.schemas import Quiz


def _quiz(quiz_id: str, choices: list[str], correct: str) -> Quiz:
    return Quiz(
        quiz_id=quiz_id,
        file_path="a.py",
        scenario="s",
        question_text="[BLANK]",
        code_snippet="____",
        choices=choices,
        correct_answer=correct,
        explanation="e",
    )


class TestChoiceOrder:
    def test_correct_answer_is_not_always_first(self):
        """正解の位置が先頭に偏っていないこと。"""
        positions = Counter()
        for sections in SAMPLE_REPOSITORIES.values():
            for section in sections:
                for quiz in section.quizzes:
                    positions[quiz.choices.index(quiz.correct_answer)] += 1

        total = sum(positions.values())
        assert total > 0
        # 4択なので理想は各25%。偏りの検出が目的なので、半分を超えたら異常とみなす。
        assert positions[0] <= total / 2, f"正解が先頭に偏っている: {dict(positions)}"
        assert len(positions) >= 2, f"正解が1か所に固まっている: {dict(positions)}"

    def test_order_is_stable_for_the_same_quiz_id(self):
        """同じIDなら何度作っても同じ並びになること（キャッシュと整合させるため）。"""
        a = _quiz("q-1", ["alpha", "beta", "gamma", "delta"], "alpha")
        b = _quiz("q-1", ["alpha", "beta", "gamma", "delta"], "alpha")
        assert a.choices == b.choices

    def test_order_does_not_depend_on_input_order(self):
        """入力の並びが違っても同じ結果になること（再構築で順が変わらない）。"""
        a = _quiz("q-2", ["alpha", "beta", "gamma", "delta"], "alpha")
        b = _quiz("q-2", ["delta", "gamma", "beta", "alpha"], "alpha")
        assert a.choices == b.choices

    def test_choices_are_preserved(self):
        """並べ替えても選択肢の中身と正解は変わらないこと。"""
        original = ["alpha", "beta", "gamma", "delta"]
        quiz = _quiz("q-3", list(original), "alpha")
        assert sorted(quiz.choices) == sorted(original)
        assert quiz.correct_answer in quiz.choices

    def test_short_choice_lists_are_left_alone(self):
        """選択肢が1つ以下なら何もしないこと。"""
        quiz = _quiz("q-4", ["only"], "only")
        assert quiz.choices == ["only"]
