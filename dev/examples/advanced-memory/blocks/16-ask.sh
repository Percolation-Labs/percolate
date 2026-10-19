for RUN in $(psql "$P8_DSN" -Atc "select r.id from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id where d.name = 'embed_text'"); do
  waiting $RUN embed
done
RUN=$(start ask_notes '{"question": "why did the team stay on Postgres?"}')
show $RUN
