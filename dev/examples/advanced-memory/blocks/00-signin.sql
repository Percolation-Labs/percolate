select set_config('request.jwt.claims', json_build_object('sub',
         (select id from rbac.users where email = 'me@example.com'))::text, false) is not null as signed_in;
