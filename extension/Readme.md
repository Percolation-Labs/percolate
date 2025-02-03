# The Zig P8 Extension

On Mac 

```bash
brew install zig
```

inside p8

```
zig init
```

Generally a folder structure for zig

```bash

my_extension/
├── src/
│   └── p8.zig
├── sql/
│   └── p8.sql
├── p8.control
└── build.zig
```
see https://zig.guide/build-system/zig-build to understand build

```
zig build
```

Local dev

```
cp p8.so $(pg_config --pkglibdir)/
cp sql/p8.sql $(pg_config --sharedir)/extension/
cp p8.control $(pg_config --sharedir)/extension/
```


https://ziggit.dev/t/how-to-package-a-zig-source-module-and-how-to-use-it/3457


- zig fetch the open ssl url to has the hash in zon
- 
- 

brew install libpq
brew link --overwrite libpq --force

 
pg_config --libdir


pg_config --pkglibdir

or test in psql
LOAD '/path/to/p8.so';
SELECT your_extension_function('test_parameter');

check compat
ldd p8.so  # Linux
otool -L p8.dylib  # macOS

pg_test_fsync


need this or error missing magic block

extern fn PG_MODULE_MAGIC() void;
export fn _PG_init() void {
    PG_MODULE_MAGIC();
}
