; Scopes
(function_declaration) @local.scope
(block) @local.scope
(for_statement) @local.scope
(closure) @local.scope

; Definitions
(variable_declaration
  name: (identifier) @local.definition)

(let_declaration
  name: (identifier) @local.definition)

(short_var_declaration
  name: (identifier) @local.definition)

(parameter
  name: (identifier) @local.definition)

(receiver
  name: (identifier) @local.definition)

; References
(identifier) @local.reference
