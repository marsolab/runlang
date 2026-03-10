; Function definitions
(function_declaration
  name: (identifier) @name) @definition.function

(pub_declaration
  declaration: (function_declaration
    name: (identifier) @name)) @definition.function

; Struct definitions
(struct_declaration
  name: (identifier) @name) @definition.class

; Interface definitions
(interface_declaration
  name: (identifier) @name) @definition.interface

; Type definitions
(type_declaration
  name: (identifier) @name) @definition.type

; Method signatures in interfaces
(method_signature
  name: (identifier) @name) @definition.method

; Function calls
(call_expression
  function: (identifier) @name) @reference.call

(call_expression
  function: (field_access
    field: (identifier) @name)) @reference.call
