%option reentrant extra-type="struct scan_ctx *"
%option noinput nounput noyywrap
%option 8bit
/* Written by Iweidieng Iep on 2020-04-12 */
/* Conforms to ISO C99 (but with a non-ISO function `fileno()`) and ISO C++11 */
/* The Flex reentrant API is used; no global non-function variables are used */

/* Rev.1 by Iweidieng Iep on 2020-04-13
 - Fix the stack of indentation level being shared instead of being copied
 - Fix initial empty lines not skipped
 - Redefine `struct stack` into `STACK(Type)` types to avoid manual casts
 - `stack_t::capa == 0` now represents a capacity of `0` instead of `1`
 - Perform bracket matching
 - The stack of indentation level now never be copied nor shared
 - Improve the error handling system to allow formatting and backtracing
 - Eliminate backing up caused by the rules */
%{
    #include <ctype.h>
    #include <limits.h>
    #include <stdarg.h>
    #include <stdbool.h>
    #include <stddef.h>
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>

    #ifdef __cplusplus
    template <class Type> using Identity = Type;
    #define LISTLIT(Type) Identity<Type>
    #define TEMPLVAL(Type, ...)                                                    \
        const_cast<LISTLIT(Type) &>((const LISTLIT(Type) &)LISTLIT(Type)           \
                                        __VA_ARGS__)
    #else
    #define LISTLIT(Type) (Type)
    #define TEMPLVAL(Type, ...) LISTLIT(Type) __VA_ARGS__
    #endif

    struct scan_ctx;
    struct error_info;
    int baosr_init_extra(struct scan_ctx * extra, yyscan_t scanner);
    int baosr_destroy(yyscan_t scanner);

    /* Stack */

    #ifdef __cplusplus
    template <bool b> struct Static_Assert {
        char x : 2 * b - 1;
    };
    #define STATIC_ASSERT_EXPR(n) ((void)sizeof(struct Static_Assert<(n)>))
    #else
    #define STATIC_ASSERT_EXPR(n) ((void)sizeof(struct { char x : 2 * !!(n)-1; }))
    #endif

    #define PTR_TO_TYPE_OF(ptr, src)                                               \
        ((void)0, ((true) ? NULL : (ptr)) + (uintptr_t)(src) / sizeof(*(ptr)))

    #define STACK_SIZE_BIT (sizeof(size_t) * CHAR_BIT - 8)
    static inline size_t capa_value(size_t capa) { return (1 << capa) >> 1; }
    #define STACK(Type)                                                            \
        struct {                                                                   \
            ptrdiff_t size : STACK_SIZE_BIT;                                       \
            size_t capa : 8;                                                       \
            Type(*items);                                                          \
        }
    typedef STACK(void) stack_t;
    #define STACK_CAST(st)                                                         \
        ((stack_t *)((void)sizeof((st)->size & 0), (void)sizeof((st)->capa & 0),   \
                     (void)sizeof((st)->items[0]),                                 \
                     STATIC_ASSERT_EXPR(sizeof(*(st)) == sizeof(stack_t)),         \
                     STATIC_ASSERT_EXPR(sizeof(ptrdiff_t) + sizeof((st)->items)    \
                                        == sizeof(stack_t)),                       \
                     (st)))
    #define STACK_TOP_RAW(st, n)                                                   \
        PTR_TO_TYPE_OF(((st)->items), stack_top_raw(STACK_CAST((st)),              \
                                                    sizeof((st)->items[0]), (n)))
    static inline void *stack_top_raw(const stack_t *st, ptrdiff_t item_sz,
                                      ptrdiff_t n)
    {
        return (char *)st->items + item_sz * (st->size - 1 - n);
    }
    #define STACK_TOP(st, n)                                                       \
        PTR_TO_TYPE_OF(((st)->items),                                              \
                       stack_top(STACK_CAST((st)), sizeof((st)->items[0]), (n)))
    static inline void *stack_top(const stack_t *st, ptrdiff_t item_sz,
                                  ptrdiff_t n)
    {
        return (st->size > 0) ? stack_top_raw(st, item_sz, n) : NULL;
    }
    #define STACK_ALLOC(st, capa, ectx)                                            \
        PTR_TO_TYPE_OF((st), stack_alloc(STACK_CAST((st)), (capa),                 \
                                         sizeof((st)->items[0]), (ectx)))
    static stack_t *stack_alloc(stack_t* st, size_t capa, size_t membsz,
                                struct error_info * ectx);
    #define STACK_PUSH(st, data, ectx)                                             \
        PTR_TO_TYPE_OF((st), stack_push(STACK_CAST((st)), (data), 1,               \
                                        sizeof((st)->items[0] = *(data)), (ectx)))
    #define STACK_APPEND(st, arr, ectx)                                            \
        PTR_TO_TYPE_OF((st),                                                       \
                       stack_push(STACK_CAST((st)), (arr),                         \
                                  sizeof(*(arr)) / sizeof((*(arr))[0]),            \
                                  sizeof((st)->items[0] = (*(arr))[0]), (ectx)))
    static stack_t *stack_push(stack_t* st, const void *data, size_t count,
                               size_t sz, struct error_info *ectx);
    #define STACK_POP(st, n, ectx) stack_pop(STACK_CAST((st)), (n), (ectx))
    static bool stack_pop(stack_t* st, size_t count, struct error_info * ectx);

    /* Error handling */

    #define ERROR_EXIT_FATAL 3

    enum errfmt_tag { EF_END, EF_C, EF_I, EF_S };
    struct errfmt {
        enum errfmt_tag tag;
        union {
            char c;
            int i;
            char *s;
        } u;
    };
    typedef STACK(struct errfmt) errmsg_arr_t;

    enum errlevel { EL_NONE, EL_WARN, EL_FATAL, EL_ASK };
    struct error_info {
        enum errlevel level;
        errmsg_arr_t *func;
        errmsg_arr_t *msg;
    };

    static inline errmsg_arr_t *errmsg_make(errmsg_arr_t* st, ...)
    {
        va_list args;
        struct error_info ectx = {EL_NONE, NULL, NULL};
        if (!st) {
            st = PTR_TO_TYPE_OF(st, malloc(sizeof(*st)));
            *st = LISTLIT(errmsg_arr_t){0, 0, NULL};
        }

        va_start(args, st);
        for (;;) {
            const int tag = va_arg(args, int);
            struct errfmt fmt = {(enum errfmt_tag)tag, {0}};
            switch (tag) {
            case EF_C:
                fmt.u.c = (char)va_arg(args, int);
                (void)STACK_PUSH(st, &fmt, &ectx);
                break;
            case EF_I:
                fmt.u.i = va_arg(args, int);
                (void)STACK_PUSH(st, &fmt, &ectx);
                break;
            case EF_S: {
                const char *str = va_arg(args, const char *);
                size_t len = strlen(str) + 1;
                fmt.u.s = PTR_TO_TYPE_OF(fmt.u.s, malloc(len));
                memcpy(fmt.u.s, str, len);
                (void)STACK_PUSH(st, &fmt, &ectx);
                break;
            }
            default:
                goto for_end;
            }
        }
    for_end:
        va_end(args);
        return st;
    }
    static inline void errmsg_print(const errmsg_arr_t *msg)
    {
        for (ptrdiff_t i = 0, n = msg->size; i < n; ++i) {
            struct errfmt *const fmt = &msg->items[i];
            switch (fmt->tag) {
            case EF_C:
                fprintf(stderr, "%c", fmt->u.c);
                break;
            case EF_I:
                fprintf(stderr, "%d", fmt->u.i);
                break;
            case EF_S:
                fprintf(stderr, "%s", fmt->u.s);
                break;
            default:
                break;
            }
        }
    }
    static inline void errmsg_free(errmsg_arr_t* msg)
    {
        if (!msg)
            return;
        for (ptrdiff_t i = 0, n = msg->size; i < n; ++i) {
            if (msg->items[i].tag == EF_S)
                free(msg->items[i].u.s);
        }
        free(msg->items);
        free(msg);
    }

    #define ERROR_BACKTRACE_FMT(str)                                               \
        EF_S, "\n\t" #str " `", EF_S, __func__, EF_S, "()` at line ", EF_I, __LINE__
    #define ERROR_THROW(ectx, lv, ...)                                          \
        do {                                                                       \
            error_set((lv), \
                      errmsg_make((ectx)->func, ERROR_BACKTRACE_FMT(Throwed from), \
                                  EF_END),                                         \
                      errmsg_make((ectx)->msg, __VA_ARGS__), (ectx));              \
            return NULL;                                                           \
        } while (0)
    #define ERROR_RETHROW(ectx)                                                    \
        do {                                                                       \
            error_set((ectx)->level,                                               \
                errmsg_make((ectx)->func, ERROR_BACKTRACE_FMT(From), EF_END),      \
                (ectx)->msg, (ectx));                                              \
            return NULL;                                                           \
        } while (0)
    static inline void error_set(int level, errmsg_arr_t* func, errmsg_arr_t* msg,
                                 struct error_info * ectx)
    {
        if (level > (int)ectx->level)
            ectx->level = (enum errlevel)level;
        ectx->func = func;
        ectx->msg = msg;
    }
    #define ERROR_CHECK(ectx, lv, ...)                                          \
        ((void)0,                                                                  \
         error_check((ectx), (lv), (YY_CURRENT_BUFFER->yy_is_interactive) ? yyin : NULL,                                                       \
                     (__VA_ARGS__)                                                 \
                         || (error_set((ectx)->level,\
                                      errmsg_make((ectx)->func,                   \
                                                   ERROR_BACKTRACE_FMT(Caught in), \
                                                   EF_END),                        \
                                       (ectx)->msg, (ectx)),           \
                             false)))
    static inline bool error_check(struct error_info * ectx, int level, FILE *file_ask, bool noerror)
    {
        if (!noerror || (int)ectx->level > level) {
            if (ectx->level >= EL_FATAL)
                fprintf(stderr, "Fatal error");
            else
                fprintf(stderr, "Warning");
            for (errmsg_arr_t **const arr[] = {&ectx->msg, &ectx->func},
                                      **const *it = arr;
                 it < (&arr)[1]; ++it) {
                if (**it) {
                    fprintf(stderr, ": ");
                    errmsg_print(**it);
                    errmsg_free(**it);
                    **it = NULL;
                }
            }
            fprintf(stderr, "\n");
            if (ectx->level < EL_FATAL && level == (int)EL_ASK && file_ask) {
                char ans[3];
                fflush(file_ask);
                fprintf(stderr, "Ignore and continue? [Y/n] ");
                if (tolower(*fgets(ans, sizeof(ans), file_ask)) == 'n')
                    ectx->level = EL_FATAL;
                else
                    ectx->level = EL_NONE;
                fflush(file_ask);
            }
            if (ectx->level >= EL_FATAL)
                exit(ERROR_EXIT_FATAL);
            ectx->level = EL_NONE;
        }
        return noerror;
    }

    /* Scanner context */

    /* Stack of indention states which are stacks of indentation levels */
    /* (stack-of-stack; for off-side rule implementation) */
    /* state 0     (0x7fffdea37320) '\0'   0sp  4sp  8sp  12sp
    /  state 1     (0x7fffdea3d430) '}'    0sp  4sp  8sp  9sp
    /  state 2     (0x7fffdea3d460) ']'    3sp  4sp  14sp
    /  stack       (0x7fffdea3d490) symbol 0    1    2    ...  (sp: spaces) */
    // Each `FRONT_INDENTED` adds a new level,
    // and each `BACK_INDENTED` removes a new level
    // Each bracket-enclosed scope has a separated state

    typedef STACK(int) int_stack_t;
    typedef STACK(int_stack_t) state_stack_t;

    static inline bool indent_state_push(state_stack_t* st, char ch,
                                         struct error_info *ectx)
    {
        return STACK_PUSH(st,
                          STACK_APPEND(&TEMPLVAL(int_stack_t, {0, 0, NULL}),
                                       &TEMPLVAL(int[2], {ch, 0}), ectx),
                          ectx);
    }
    static bool indent_state_pop(state_stack_t* st, char ch,
                                 struct error_info *ectx);
    static void indent_state_print(const state_stack_t *st, FILE *out);
    static inline bool indent_state_init(state_stack_t* st,
                                         struct error_info * ectx)
    {
        return ((void)(*st = LISTLIT(state_stack_t){0, 0, NULL}),
                indent_state_push(st, '\0', ectx));
    }
    static void indent_state_destroy(state_stack_t* st,
                                     struct error_info * ectx);

    /* Token emitters */

    static void emit_token(const char *content, const char *name,
                           yyscan_t scanner);

    static void emit_indent_token(const char *type, const state_stack_t *st,
                                  yyscan_t scanner);
    static bool emit_indent(int width, yyscan_t scanner);
    static int indent_width(const char *indent, size_t len_raw,
                            yyscan_t scanner);

    #define TAB_WIDTH_DEFAULT 8

    struct scan_ctx {
        state_stack_t indent_state;
        struct error_info errinfo;
        int tab_width;
    };
%}

%s IST_INITIAL

%option nodefault
%%
    state_stack_t *const yy_indent_state = &yyextra->indent_state;
    struct error_info *const yy_errinfo = &yyextra->errinfo;

    #define EXIT_INITIAL()                                                         \
        ((void)((YY_START == INITIAL) && (BEGIN(IST_INITIAL), REPORT_INDENT(), 0)))
    #define EMIT_TOKEN(content, name)                                              \
        (EXIT_INITIAL(), emit_token(content, name, yyscanner))
    #define PUSH_INDENT_STATE(ch)                                                  \
        ERROR_CHECK(yy_errinfo, EL_ASK,                                                     \
                    indent_state_push(yy_indent_state, (ch), yy_errinfo))
    #define POP_INDENT_STATE(ch)                                                   \
        ERROR_CHECK(yy_errinfo, EL_ASK, indent_state_pop(yy_indent_state, (ch), yy_errinfo))
    #define REPORT_INDENT() emit_indent_token("", yy_indent_state, yyscanner)


    /* Indentation and whitespace */
<INITIAL>[ \t]+\n   |
<INITIAL>\n+        { } // Initial empty lines
<INITIAL>[ \t]+     { // First non-empty line, with indentation
                        BEGIN(IST_INITIAL);
                        STACK_TOP_RAW(yy_indent_state, 0)->items[1] =
                            indent_width(yytext, yyleng, yyscanner); // Level 0 indentation
                        REPORT_INDENT();
                    }
<IST_INITIAL>\n[ \t]*\n { yyless(yyleng - 1); } // Empty line
<IST_INITIAL>\n[ \t]*   { // Indentation
                            ERROR_CHECK(yy_errinfo, EL_WARN,
                                        emit_indent(indent_width(yytext + 1, yyleng - 1, yyscanner),
                                                    yyscanner));
                        }
\n+     { } // Discard other line ends
[ \t]+  { } // Discard other spaces

    /* Words */
(?i:indent)     {
                    indent_state_print(yy_indent_state, yyout);
                    EMIT_TOKEN(yytext, "TOK_INDENT_STATE_PRINT");
                }
(?i:tab)[0-9]+  {
                    yyextra->tab_width = atoi(yytext + 3);
                    EMIT_TOKEN(yytext, "TOK_TAB_WIDTH_SET");
                }
[0-9a-zA-Z_]+   { EMIT_TOKEN(yytext, "TOK_WORD"); }

    /* Brackets */
[({[]  {
           const char ch = yytext[0];
           PUSH_INDENT_STATE(((ch) == '{') ? '}' : ((ch) == '[') ? ']' : ')');
           BEGIN(INITIAL);
           emit_token(yytext, "TOK_OPEN_BRACKET", yyscanner);
       }
[]})]  {
           POP_INDENT_STATE(yytext[0]);
           EMIT_TOKEN(yytext, "TOK_CLOSE_BRACKET");
           REPORT_INDENT();
       }

    /* End of file */
<<EOF>>         { yyterminate(); }

    /* Other characters are delimiters */
[^ \t\n({[\]})0-9a-zA-Z_]+    { EMIT_TOKEN(yytext, "TOK_DELIMITER"); }

%%
/* Token emitters */

static void emit_token(const char *content, const char *name,
                       yyscan_t scanner)
{
    // Align the output against the last line
    const char *last_nl = strrchr(content, '\n');
    const int prev_len = (last_nl) ? last_nl - content : 0;
    fprintf(yyget_out(scanner), "%.*s%-8s \t %s\n", prev_len, content, content,
            name);
}

static void emit_indent_token(const char *type, const state_stack_t *st,
                              yyscan_t scanner)
{
    char buf[sizeof("HALF_BACK_INDENTED (state 18446744073709551615; level "
                    "18446744073709551615; 18446744073709551615sp)")];
    snprintf(buf, sizeof(buf), "%-*s(state %zd; level %zd; %dsp)",
             (*type) ? (int)(unsigned)strlen(type) + 1 : 0, type,
             (ptrdiff_t)st->size - 1, (ptrdiff_t)STACK_TOP(st, 0)->size - 2,
             *STACK_TOP(STACK_TOP(st, 0), 0));
    emit_token("", buf, scanner);
}

static bool emit_indent(int width, yyscan_t scanner)
{
    struct error_info *const ectx = &yyget_extra(scanner)->errinfo;
    state_stack_t *const st = &yyget_extra(scanner)->indent_state;
    int_stack_t *const lv_st = STACK_TOP_RAW(st, 0);
    int sp_prev = (lv_st->size > 2) ? *STACK_TOP_RAW(lv_st, 0)
                                    : lv_st->items[1];

    if (width > sp_prev) {
        if (!STACK_PUSH(lv_st, &width, ectx))
            ERROR_RETHROW(ectx);
        emit_indent_token("FRONT_INDENTED", st, scanner);
        return true;
    }
    if (width == sp_prev) {
        emit_indent_token("NO_INDENTED", st, scanner);
        return true;
    }
    while (width < sp_prev) {
        if (lv_st->size <= 2) {
            lv_st->items[1] = width; // Decrease level 0 indentation
            emit_indent_token("SEMI_BACK_INDENTED", st, scanner);
            break;
        }
        sp_prev = *STACK_TOP_RAW(lv_st, 1);
        if (width > sp_prev) {
            emit_indent_token("SEMI_NO_INDENTED", st, scanner);
            break;
        }
        STACK_POP(lv_st, 1, ectx);
        emit_indent_token("BACK_INDENTED", st, scanner);
    }
    return true;
}

static int indent_width(const char *indent, size_t len_raw, yyscan_t scanner)
{
    const int tab_width = yyget_extra(scanner)->tab_width;
    int len = 0;
    for (const char *ch = indent, *end = indent + len_raw; ch < end;) {
        const char *const sp_end = PTR_TO_TYPE_OF(sp_end, memchr(ch, '\t', end - ch));
        if (sp_end) {
            len += sp_end - ch;
            ch += sp_end - ch;
            while (ch < end && *ch++ == '\t')
                len += tab_width - len % tab_width;
        } else {
            len += end - ch;
            ch += end - ch;
            break;
        }
    }
    return len;
}

/* Stack of indention states which are stacks of indentation levels */

static stack_t *stack_alloc(stack_t *st, size_t capa, size_t membsz,
                            struct error_info *ectx)
{
    if (capa > STACK_SIZE_BIT) {
        ERROR_THROW(ectx, EL_WARN, EF_S, "argument `capa` is too large", EF_END);
    }
    void *const items = realloc(st->items, capa_value(capa) * membsz);
    if (!items)
        ERROR_THROW(ectx, EL_FATAL, EF_S, "`realloc()` failed", EF_END);
    st->items = items;
    st->capa = capa;
    return st;
}

static stack_t *stack_push(stack_t *st, const void *data, size_t count,
                           size_t sz, struct error_info *ectx)
{
    if (!data)
        ERROR_RETHROW(ectx);
    while (st->size + count > capa_value(st->capa)) {
        if (!stack_alloc(st, st->capa + 1, sz, ectx))
            ERROR_RETHROW(ectx);
    }
    memcpy(stack_top_raw(st, sz, -1), data, count * sz);
    st->size += count;
    return st;
}

static bool stack_pop(stack_t *st, size_t count, struct error_info *ectx)
{
    if (st->size < 0 || (size_t)st->size < count)
        ERROR_THROW(ectx, EL_WARN, EF_S, "Too much elements to pop: ", EF_I, (int)count,
                    EF_S, "; size of stack: ", EF_I, EF_END);
    st->size -= count;
    return true;
}

static void indent_state_destroy(state_stack_t *st, struct error_info *ectx)
{
    (void)ectx;
    for (ptrdiff_t i = 0, n = st->size; i < n; ++i) {
        free(st->items[i].items);
    }
    free(st->items);
    *st = LISTLIT(state_stack_t){0, 0, NULL};
}

static bool indent_state_pop(state_stack_t *st, char ch,
                             struct error_info *ectx)
{
    if ((st->size > 1 && STACK_TOP_RAW(st, 0)->items[0])) {
        if (STACK_TOP_RAW(st, 0)->items[0] != ch) {
            ERROR_THROW(ectx, EL_WARN, EF_S, "Incorrect closing bracket `", EF_C, ch,
                        EF_S, "`; expected: `", EF_C,
                        STACK_TOP(st, 0)->items[0], EF_S, "`", EF_END);
        }
    } else {
        ERROR_THROW(ectx, EL_WARN, EF_S, "Unbalanced closing bracket `", EF_C, ch, EF_S,
                    "`", EF_END);
    }
    free(STACK_TOP_RAW(st, 0)->items);
    STACK_POP(st, 1, ectx);
    return true;
}

static void indent_state_print(const state_stack_t *st, FILE *out)
{
    ptrdiff_t max_size = 1;
    for (ptrdiff_t i = 0, n = st->size; i < n; ++i) {
        const int_stack_t *const lv_st = &st->items[i];
        fprintf(out, "state %-5zu (%p) ", i, (const void *)lv_st->items);
        if (lv_st->size > max_size + 1)
            max_size = lv_st->size - 1;
        if (lv_st->size > 0) {
            const int *const k = &lv_st->items[0];
            if (*k)
                fprintf(out, "'%c'    ", *k);
            else
                fprintf(out, "'\\0'   ");
            for (ptrdiff_t j = 1, m = lv_st->size; j < m; ++j) {
                const int *const k = &lv_st->items[j];
                fprintf(out, "%dsp%*s ", *k, *k < 10, "");
            }
        }
        fprintf(out, "\n");
    }
    fprintf(out, "stack       (%p) ", (const void *)st->items);
    fprintf(out, "symbol ");
    for (ptrdiff_t i = 0; i < max_size; ++i)
        fprintf(out, "%-4zd ", i);
    fprintf(out, "...  (sp: spaces)\n");
}

int yy_scanner_init_extra(struct scan_ctx *ctx, yyscan_t *pscanner)
{
    *ctx =
        LISTLIT(struct scan_ctx){{0, 0, NULL}, {EL_NONE, NULL, NULL}, TAB_WIDTH_DEFAULT};
    if (yylex_init_extra(ctx, pscanner))
        return 1;
    return !indent_state_init(&ctx->indent_state, &ctx->errinfo);
}

int yy_scanner_destroy(yyscan_t scanner)
{
    indent_state_destroy(&yyget_extra(scanner)->indent_state,
                         &yyget_extra(scanner)->errinfo);
    return yylex_destroy(scanner);
}

int main(void)
{
    yyscan_t scanner;
    struct scan_ctx ctx;

    if (yy_scanner_init_extra(&ctx, &scanner)) {
        perror("`scanner_init_extra()`");
        return 1;
    }
    yylex(scanner);
    yy_scanner_destroy(scanner);
}
