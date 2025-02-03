cp ./sql/p8.sql /usr/local/opt/postgresql@16/share/postgresql@16/extension/p8--1.0.sql

cp ./p8.control /usr/local/opt/postgresql@16/share/postgresql@16/extension/

cp zig-out/lib/p8.dylib /usr/local/opt/postgresql@16/lib/postgresql

chmod 644 /usr/local/opt/postgresql@16/share/postgresql@16/extension/p8--1.0.sql
chmod 644 /usr/local/opt/postgresql@16/share/postgresql@16/extension/p8.control
chmod 755 /usr/local/opt/postgresql@16/lib/p8.dylib

#brew services restart postgresql@16