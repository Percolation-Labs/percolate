# The two worked examples: each rubric item of BEAM's reference answer, the exchange the walk read for it, when and
# how, with the coverage and the compressed path drawn beside it (examples/<name>-*.png).
#
# Evaluation harness, not product: BEAM's answer and rubric come from the downloaded questions.jsonl, our grouping of
# the evidence into the rubric's items from harness/answer-items.json; walk-0's evidence from its own questions file.
# Everything else is the run's own rows. The runs are steps 1, 2 and 3's, found by their questions' words.
mkdir -p examples
run() { psql "$P8_DSN" -At -v q="$1" <<<"select run from aiq.walk_runs where question_text = :'q' and control_of is null order by created_at limit 1"; }
python3 harness/examples.py "$P8_DSN" "$(run 'How did my focus on different aspects of the holiday celebration evolve throughout our conversations in order? Mention ONLY and ONLY seven items.')" \
  1M:35:event_ordering:0 examples/holiday
python3 harness/examples.py "$P8_DSN" "$(run 'Considering my budget, tool priorities, ladder needs, and moving help, how should I sequence and allocate resources to complete my DIY projects safely and efficiently?')" \
  1M:22:multi_session_reasoning:1 examples/ladder
python3 harness/examples.py "$P8_DSN" "$(run walk-0/q6)" walk-0/q6 examples/q6
