select e ->> 'code' as code, e -> 'evidence' as evidence
  from jsonb_array_elements(aiq.query('TEXT "berth" FROM chunks LIMIT 1') -> 'exceptions') e;
select e ->> 'code' as code, e ->> 'prompt' as prompt
  from jsonb_array_elements(aiq.query('TEXT "zeppelin" FROM chunks') -> 'exceptions') e;
