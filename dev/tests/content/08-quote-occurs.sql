-- A QUOTE IS EVIDENCE BY ONE RULE, whoever checks it (REM-59).
--
-- Eight copies of "is the model's quote in its source" disagreed: a quote in
-- asterisks, or with smart quotes, passed the self-model scripts and failed
-- pgvector-watch, and a four-letter quote passed the tour and failed the rest.
-- Every case below is one those copies decided differently. The rule is
-- extraction.md §4.2; aiq.quote_occurs is the only implementation.

\set ON_ERROR_STOP on

begin;

do $$
declare
    src text := 'Building an HNSW index with maintenance_work_mem = 8GB fails with '
                '''out of memory'' after about 40 minutes.';
    c record;
begin
    for c in select * from (values
        -- what a model does to a verbatim quote, none of which is fabrication
        ('verbatim',            'fails with ''out of memory''',                      true),
        ('asterisks',           '*fails with ''out of memory''*',                    true),
        ('backticks',           'with `maintenance_work_mem` = 8GB',                 true),
        ('smart quotes',        E'fails with ‘out of memory’',             true),
        ('double for single',   'fails with "out of memory"',                        true),
        ('whitespace run',      E'fails  with\n''out of memory''',                   true),
        ('upper case',          'FAILS WITH ''OUT OF MEMORY''',                      true),
        ('edge punctuation',    '"after about 40 minutes."',                         true),
        -- what is not evidence
        ('too short',           'HNSW',                                              false),
        ('short once trimmed',  '"  HNSW. "',                                        false),
        ('paraphrase',          'fails with out-of-memory after forty minutes',      false),
        ('not there',           'fails with ''out of disk''',                        false),
        ('empty',               '',                                                  false),
        ('null',                null,                                                false)
    ) as t(name, quote, expected)
    loop
        if aiq.quote_occurs(c.quote, src) is distinct from c.expected then
            raise exception 'aiq.quote_occurs: % (%) should be %', c.name, c.quote, c.expected;
        end if;
    end loop;

    if aiq.quote_occurs('fails with ''out of memory''', null) then
        raise exception 'aiq.quote_occurs found a quote in a null source';
    end if;

    raise notice 'content: a quote is evidence by one rule, aiq.quote_occurs';
end $$;

rollback;
