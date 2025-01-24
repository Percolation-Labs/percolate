PG_CONFIG = pg_config
EXT_NAME = hello_world
SRC_DIR = src
OBJ_DIR = obj
LIB_DIR = $(OBJ_DIR)/lib
OBJ = $(SRC_DIR)/hello_world.zig

CC = zig cc

CFLAGS = -O3
LDFLAGS = -shared

# Get PostgreSQL C flags and libraries from pg_config
PG_CFLAGS = $(shell $(PG_CONFIG) --cflags)
PG_LIBS = $(shell $(PG_CONFIG) --libs)

all: $(OBJ_DIR)/hello_world.so

$(OBJ_DIR)/hello_world.so: $(OBJ)
	$(CC) $(CFLAGS) $(PG_CFLAGS) $(OBJ) -o $@ $(LDFLAGS) $(PG_LIBS)

$(OBJ_DIR)/hello_world.o: $(SRC_DIR)/hello_world.zig
	zig build-lib $(SRC_DIR)/hello_world.zig -dynamic -o $(OBJ_DIR)/hello_world.so

install: all
	cp $(OBJ_DIR)/hello_world.so $(PG_LIB_DIR)
	cp sql/*.sql $(EXTENSION_SQL_DIR)
clean:
	rm -rf $(OBJ_DIR)