; Keywords
; Keywords used in sequences (anonymous nodes)
[
  "fun"
  "pub"
  "var"
  "let"
  "return"
  "if"
  "else"
  "for"
  "in"
  "switch"
  "defer"
  "run"
  "try"
  "package"
  "use"
  "struct"
  "interface"
  "implements"
  "type"
  "chan"
  "map"
  "alloc"
  "and"
  "or"
  "not"
] @keyword

; break and continue are full statement nodes
(break_statement) @keyword
(continue_statement) @keyword

; Literals
(int_literal) @number
(float_literal) @number.float
(string_literal) @string
(char_literal) @character
(bool_literal) @boolean
(null_literal) @constant.builtin

; Comments
(line_comment) @comment

; Functions
(function_declaration
  name: (identifier) @function)

(method_signature
  name: (identifier) @function.method)

(call_expression
  function: (identifier) @function.call)

(call_expression
  function: (field_access
    field: (identifier) @function.method.call))

; Closures
(closure) @function

; Types
(simple_type) @type

(struct_declaration
  name: (identifier) @type)

(interface_declaration
  name: (identifier) @type)

(type_declaration
  name: (identifier) @type)

; Parameters & variables
(parameter
  name: (identifier) @variable.parameter)

(receiver
  name: (identifier) @variable.parameter)

(variable_declaration
  name: (identifier) @variable)

(let_declaration
  name: (identifier) @variable)

(short_var_declaration
  name: (identifier) @variable)

; Fields
(field_declaration
  name: (identifier) @property)

(field_access
  field: (identifier) @property)

(struct_field_init
  name: (identifier) @property)

; Package
(package_declaration
  name: (identifier) @module)

(import_declaration
  path: (string_literal) @string.special)

; Operators
[
  "+"
  "-"
  "*"
  "/"
  "%"
  "=="
  "!="
  "<"
  ">"
  "<="
  ">="
  "="
  ":="
  "<-"
  ".."
  "::"
  "|"
  "!"
  "&"
  "@"
  "?"
] @operator

; Punctuation
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["," "." ":"] @punctuation.delimiter

; Variant
(variant_expression
  (identifier) @constant)

(variant_definition
  (identifier) @constant)

(variant_pattern
  (identifier) @constant)

; Wildcard pattern
"_" @variable.builtin
