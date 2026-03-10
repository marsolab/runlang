/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

// Precedence levels (highest to lowest)
const PREC = {
  OR: 1,
  AND: 2,
  COMPARE: 3,
  RANGE: 4,
  ADD: 5,
  MULTIPLY: 6,
  UNARY: 7,
  POSTFIX: 8,
  PRIMARY: 9,
};

module.exports = grammar({
  name: "run",

  extras: ($) => [/[ \t\r]/, $.line_comment],

  externals: ($) => [],

  word: ($) => $.identifier,

  conflicts: ($) => [
    [$.simple_type, $._primary],
    [$.variant_pattern, $.variant_expression],
    [$.variant_pattern, $._primary],
  ],

  rules: {
    source_file: ($) =>
      seq(
        repeat("\n"),
        optional($.package_declaration),
        repeat(
          seq(
            choice(
              $.import_declaration,
              $.function_declaration,
              $.struct_declaration,
              $.interface_declaration,
              $.type_declaration,
              $.variable_declaration,
              $.let_declaration,
              $.pub_declaration,
            ),
            repeat1("\n"),
          ),
        ),
      ),

    // ---- Top-level declarations ----

    package_declaration: ($) =>
      seq("package", field("name", $.identifier), repeat1("\n")),

    import_declaration: ($) =>
      seq("use", field("path", $.string_literal)),

    pub_declaration: ($) =>
      seq(
        "pub",
        field(
          "declaration",
          choice(
            $.function_declaration,
            $.struct_declaration,
            $.interface_declaration,
            $.type_declaration,
            $.variable_declaration,
            $.let_declaration,
          ),
        ),
      ),

    // ---- Functions ----

    function_declaration: ($) =>
      seq(
        "fun",
        optional(field("receiver", $.receiver)),
        field("name", $.identifier),
        $.parameter_list,
        optional(field("return_type", $._type)),
        optional(field("body", $.block)),
      ),

    receiver: ($) =>
      seq(
        "(",
        field("name", $.identifier),
        optional(":"),
        field("type", $._type),
        ")",
      ),

    parameter_list: ($) =>
      seq(
        "(",
        optional(
          seq(
            $.parameter,
            repeat(seq(",", $.parameter)),
            optional(","),
          ),
        ),
        ")",
      ),

    parameter: ($) =>
      seq(
        field("name", $.identifier),
        optional(":"),
        field("type", $._type),
      ),

    // ---- Structs ----

    struct_declaration: ($) =>
      seq(
        field("name", $.identifier),
        "struct",
        $.struct_body,
      ),

    struct_body: ($) =>
      seq(
        "{",
        repeat("\n"),
        optional($.implements_clause),
        repeat(
          seq(
            $.field_declaration,
            repeat1("\n"),
          ),
        ),
        "}",
      ),

    implements_clause: ($) =>
      seq(
        "implements",
        "(",
        repeat("\n"),
        repeat(
          seq($.identifier, repeat("\n")),
        ),
        ")",
        repeat("\n"),
      ),

    field_declaration: ($) =>
      seq(
        field("name", $.identifier),
        optional(":"),
        field("type", $._type),
        optional(seq("=", field("default", $._expression))),
      ),

    // ---- Interfaces ----

    interface_declaration: ($) =>
      seq(
        "interface",
        field("name", $.identifier),
        "{",
        repeat("\n"),
        repeat(
          seq(
            $.method_signature,
            repeat1("\n"),
          ),
        ),
        "}",
      ),

    method_signature: ($) =>
      seq(
        "fun",
        field("name", $.identifier),
        $.parameter_list,
        optional(field("return_type", $._type)),
      ),

    // ---- Type declarations ----

    type_declaration: ($) =>
      seq(
        "type",
        field("name", $.identifier),
        choice(
          seq(
            "=",
            $.variant_definition,
            repeat(seq("|", $.variant_definition)),
          ),
          field("type", $._type),
        ),
      ),

    variant_definition: ($) =>
      seq(
        ".",
        $.identifier,
        optional(seq("(", $._type, ")")),
      ),

    // ---- Variables ----

    variable_declaration: ($) =>
      seq(
        "var",
        field("name", $.identifier),
        optional(field("type", $._type)),
        optional(seq("=", field("value", $._expression))),
      ),

    let_declaration: ($) =>
      seq(
        "let",
        field("name", $.identifier),
        optional(field("type", $._type)),
        "=",
        field("value", $._expression),
      ),

    short_var_declaration: ($) =>
      prec.right(
        seq(
          field("name", $._expression),
          ":=",
          field("value", $._expression),
        ),
      ),

    // ---- Types ----

    _type: ($) =>
      choice(
        $.simple_type,
        $.pointer_type,
        $.const_pointer_type,
        $.nullable_type,
        $.error_union_type,
        $.slice_type,
        $.array_type,
        $.channel_type,
        $.map_type,
        $.anonymous_struct_type,
      ),

    simple_type: ($) => $.identifier,

    pointer_type: ($) => seq("&", $._type),

    const_pointer_type: ($) => seq("@", $._type),

    nullable_type: ($) =>
      prec.left(
        PREC.POSTFIX,
        seq($._type, "?"),
      ),

    error_union_type: ($) => prec(PREC.UNARY, seq("!", $._type)),

    slice_type: ($) => seq("[", "]", $._type),

    array_type: ($) =>
      seq("[", field("size", $._expression), "]", $._type),

    channel_type: ($) =>
      seq(
        "chan",
        optional(
          choice(
            seq("[", $._type, "]"),
            $._type,
          ),
        ),
      ),

    map_type: ($) =>
      seq("map", "[", field("key", $._type), "]", field("value", $._type)),

    anonymous_struct_type: ($) =>
      seq("struct", $.struct_body),

    // ---- Statements ----

    _statement: ($) =>
      choice(
        $.variable_declaration,
        $.let_declaration,
        $.short_var_declaration,
        $.return_statement,
        $.defer_statement,
        $.break_statement,
        $.continue_statement,
        $.run_statement,
        $.if_statement,
        $.for_statement,
        $.switch_statement,
        $.assignment_statement,
        $.channel_send_statement,
        $.expression_statement,
      ),

    return_statement: ($) =>
      seq("return", optional($._expression)),

    defer_statement: ($) =>
      seq("defer", $._expression),

    break_statement: ($) => "break",

    continue_statement: ($) => "continue",

    run_statement: ($) =>
      seq("run", $._expression),

    if_statement: ($) =>
      prec.right(
        seq(
          "if",
          field("condition", $._expression),
          field("consequence", $.block),
          optional(
            seq(
              "else",
              field(
                "alternative",
                choice($.if_statement, $.block),
              ),
            ),
          ),
        ),
      ),

    for_statement: ($) =>
      choice(
        // for value in iterable { }
        // for value, index in iterable { }
        prec(2,
          seq(
            "for",
            field("value", $.identifier),
            optional(seq(",", field("index", $.identifier))),
            "in",
            field("iterable", $._non_struct_expression),
            field("body", $.block),
          ),
        ),
        // for condition { }
        seq(
          "for",
          field("condition", $._non_struct_expression),
          field("body", $.block),
        ),
        // for { }  (infinite loop)
        seq(
          "for",
          field("body", $.block),
        ),
      ),

    switch_statement: ($) =>
      seq(
        "switch",
        field("value", $._expression),
        "{",
        repeat("\n"),
        repeat(seq($.switch_arm, repeat1("\n"))),
        "}",
      ),

    switch_arm: ($) =>
      seq(
        field("pattern", $._switch_pattern),
        repeat(seq(",", $._switch_pattern)),
        "::",
        field("body", choice($.block, $._expression)),
      ),

    _switch_pattern: ($) =>
      choice(
        $.variant_pattern,
        $._expression,
        "_",
      ),

    variant_pattern: ($) =>
      seq(
        ".",
        $.identifier,
        optional(seq("(", $.identifier, ")")),
      ),

    assignment_statement: ($) =>
      prec.right(
        seq(
          field("left", $._expression),
          "=",
          field("right", $._expression),
        ),
      ),

    channel_send_statement: ($) =>
      prec.right(
        seq(
          field("channel", $._expression),
          "<-",
          field("value", $._expression),
        ),
      ),

    expression_statement: ($) => $._expression,

    // ---- Block ----

    block: ($) =>
      seq(
        "{",
        repeat("\n"),
        repeat(seq($._statement, repeat1("\n"))),
        "}",
      ),

    // ---- Expressions ----

    // _expression is the full expression set. Struct literals are only
    // produced at the top level via _expression and never leak into
    // sub-expressions, matching the parser's allow_struct_literals flag.
    _expression: ($) =>
      choice(
        $.struct_literal,
        $._non_struct_expression,
      ),

    // Core expression set that excludes struct literals.
    // All compound expression rules (binary, unary, call, etc.) reference
    // _non_struct_expression for their operands so that `identifier {`
    // is never ambiguous with block-start in if/for/switch.
    _non_struct_expression: ($) =>
      choice(
        $.binary_expression,
        $.unary_expression,
        $.call_expression,
        $.field_access,
        $.index_expression,
        $.try_expression,
        $.if_expression,
        $.closure,
        $.alloc_expression,
        $.anonymous_struct_literal,
        $.channel_receive,
        $.range_expression,
        $.variant_expression,
        $._primary,
      ),

    binary_expression: ($) =>
      choice(
        ...[
          ["or", PREC.OR],
          ["and", PREC.AND],
          ["==", PREC.COMPARE],
          ["!=", PREC.COMPARE],
          ["<", PREC.COMPARE],
          [">", PREC.COMPARE],
          ["<=", PREC.COMPARE],
          [">=", PREC.COMPARE],
          ["+", PREC.ADD],
          ["-", PREC.ADD],
          ["*", PREC.MULTIPLY],
          ["/", PREC.MULTIPLY],
          ["%", PREC.MULTIPLY],
        ].map(([op, prec_level]) =>
          prec.left(
            prec_level,
            seq(
              field("left", $._non_struct_expression),
              field("operator", op),
              field("right", $._non_struct_expression),
            ),
          ),
        ),
      ),

    unary_expression: ($) =>
      prec(
        PREC.UNARY,
        seq(
          field("operator", choice("-", "!", "not", "&", "@")),
          field("operand", $._non_struct_expression),
        ),
      ),

    call_expression: ($) =>
      prec(
        PREC.POSTFIX,
        seq(
          field("function", $._non_struct_expression),
          $.argument_list,
        ),
      ),

    argument_list: ($) =>
      seq(
        "(",
        optional(
          seq(
            $._argument,
            repeat(seq(",", $._argument)),
            optional(","),
          ),
        ),
        ")",
      ),

    _argument: ($) =>
      choice(
        $.named_argument,
        $._expression,
      ),

    named_argument: ($) =>
      seq(
        field("name", $.identifier),
        ":",
        field("value", $._expression),
      ),

    field_access: ($) =>
      prec.left(
        PREC.POSTFIX,
        seq(
          field("object", $._non_struct_expression),
          ".",
          field("field", $.identifier),
        ),
      ),

    index_expression: ($) =>
      prec(
        PREC.POSTFIX,
        seq(
          field("object", $._non_struct_expression),
          "[",
          field("index", $._expression),
          "]",
        ),
      ),

    try_expression: ($) =>
      prec.right(
        PREC.UNARY,
        seq(
          "try",
          field("expression", $._non_struct_expression),
          optional(seq("::", field("context", $.string_literal))),
        ),
      ),

    if_expression: ($) =>
      prec.right(
        seq(
          "if",
          field("condition", $._non_struct_expression),
          "::",
          field("then", $._non_struct_expression),
          "else",
          field("else", $._non_struct_expression),
        ),
      ),

    closure: ($) =>
      seq(
        "fun",
        $.parameter_list,
        optional(field("return_type", $._type)),
        field("body", $.block),
      ),

    alloc_expression: ($) =>
      seq(
        "alloc",
        "(",
        field("type", $._type),
        repeat(seq(",", $._argument)),
        ")",
      ),

    struct_literal: ($) =>
      prec(
        PREC.POSTFIX,
        seq(
          field("type", $.identifier),
          "{",
          optional($.struct_init_fields),
          "}",
        ),
      ),

    anonymous_struct_literal: ($) =>
      seq(
        ".{",
        optional($.struct_init_fields),
        "}",
      ),

    struct_init_fields: ($) =>
      seq(
        repeat("\n"),
        $.struct_field_init,
        repeat(seq(",", repeat("\n"), $.struct_field_init)),
        optional(","),
        repeat("\n"),
      ),

    struct_field_init: ($) =>
      seq(
        field("name", $.identifier),
        ":",
        field("value", $._expression),
      ),

    channel_receive: ($) =>
      prec(PREC.UNARY, seq("<-", field("channel", $._non_struct_expression))),

    range_expression: ($) =>
      prec.left(
        PREC.RANGE,
        seq(
          field("start", $._non_struct_expression),
          "..",
          field("end", $._non_struct_expression),
        ),
      ),

    variant_expression: ($) =>
      prec.left(
        seq(
          ".",
          $.identifier,
          optional(seq("(", $._expression, ")")),
        ),
      ),

    // ---- Primaries ----

    _primary: ($) =>
      choice(
        $.identifier,
        $.int_literal,
        $.float_literal,
        $.string_literal,
        $.char_literal,
        $.bool_literal,
        $.null_literal,
        $.parenthesized_expression,
      ),

    parenthesized_expression: ($) =>
      seq("(", $._expression, ")"),

    // ---- Literals ----

    identifier: ($) => /[a-zA-Z_][a-zA-Z0-9_]*/,

    int_literal: ($) =>
      token(
        choice(
          /0[xX][0-9a-fA-F][0-9a-fA-F_]*/,
          /0[oO][0-7][0-7_]*/,
          /0[bB][01][01_]*/,
          /[0-9][0-9_]*/,
        ),
      ),

    float_literal: ($) =>
      token(
        choice(
          /[0-9][0-9_]*\.[0-9][0-9_]*([eE][+-]?[0-9][0-9_]*)?/,
          /[0-9][0-9_]*[eE][+-]?[0-9][0-9_]*/,
        ),
      ),

    string_literal: ($) =>
      token(seq('"', repeat(choice(/[^"\\]/, /\\./)), '"')),

    char_literal: ($) =>
      token(seq("'", choice(/[^'\\]/, /\\./), "'")),

    bool_literal: ($) => choice("true", "false"),

    null_literal: ($) => "null",

    line_comment: ($) => token(seq("//", /[^\n]*/)),
  },
});
