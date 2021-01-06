TARGET := offside-rule-with-brace-scanner

DEBUG :=
DEBUG_ := NO
DEBUG_MODE := ${DEBUG_${DEBUG}}DEBUG

CC := g++
CFLAGS_WARN := -std=c++11 -Wall -Wextra -pedantic-errors
CFLAGS_DEBUG := -ggdb3
CFLAGS_NODEBUG := -O2
CFLAGS := ${CFLAGS_WARN} ${CFLAGS_${DEBUG_MODE}}

LEX := flex
LFLAGS_DEBUG := -b -p -L
LFLAGS_NODEBUG := -Cfe
LFLAGS := ${LFLAGS_${DEBUG_MODE}}

VERBOSE :=
VERBOSE_ := @
Q := ${VERBOSE_${VERBOSE}}

all: ${TARGET}

${TARGET}: offside-rule-with-brace.yy.c
	${Q}${CC} ${CFLAGS} -o $@ $<

%.yy.c: %.l
	${Q}${LEX} ${LFLAGS} -o $@ $<

clean:
	${Q}rm -f ${TARGET} *.yy.c
