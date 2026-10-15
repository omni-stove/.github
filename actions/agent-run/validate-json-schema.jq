# 構造化出力を JSON Schema (サブセット) で検証する。
#   jq -r --slurpfile schema <schema.json> -f validate-json-schema.jq <<<"<value>"
# 違反があれば 1 行 1 件で出力する (何も出なければ合格)。
# 対応しないキーワードを含むスキーマは、そのキーワード名を出して不合格にする
# (検証されないまま通すより、スキーマの書き手に気づかせる)。

def supported: [
  "$comment", "$id", "$schema", "additionalProperties", "allOf", "anyOf", "const", "default",
  "deprecated", "description", "enum", "examples", "items", "maxItems", "maximum", "maxLength",
  "minItems", "minimum", "minLength", "not", "oneOf", "pattern", "properties", "readOnly",
  "required", "title", "type", "writeOnly"
];

def unsupported_keywords($schema; $path):
  if ($schema | type) == "boolean" then []
  elif ($schema | type) != "object" then ["\($path) must be a schema object or boolean"]
  else
    [ $schema | keys_unsorted[] | select(IN(supported[]) | not) | "\($path).\(.) is not supported by the json-schema validator" ]
    + ([ ("additionalProperties", "items", "not") as $k | select($schema | has($k)) | unsupported_keywords($schema[$k]; "\($path).\($k)") ] | add // [])
    + ([ ($schema.properties // {}) | to_entries[] | .key as $k | unsupported_keywords(.value; "\($path).properties.\($k)") ] | add // [])
    + ([ ("allOf", "anyOf", "oneOf") as $k | ($schema[$k] // []) | to_entries[] | .key as $i | unsupported_keywords(.value; "\($path).\($k)[\($i)]") ] | add // [])
  end;

def jtype($v):
  if $v == null then "null"
  elif ($v | type) == "number" then (if $v == ($v | floor) then "integer" else "number" end)
  else ($v | type) end;

def check($schema; $value; $path):
  if $schema == true then []
  elif $schema == false then ["\($path) is forbidden by the schema"]
  else
    (($schema.type // []) | if type == "array" then . else [.] end) as $types
    | jtype($value) as $actual
    | if ($types | length) > 0 and (($types | index($actual)) == null) and (($actual == "integer" and (($types | index("number")) != null)) | not)
      then ["\($path) must be \($types | join(" or "))"]
      else
        (if ($schema | has("enum")) and (($schema.enum | any(.[]; . == $value)) | not) then ["\($path) is not in enum"] else [] end)
        + (if ($schema | has("const")) and ($schema.const != $value) then ["\($path) does not equal const"] else [] end)
        + (if ($value | type) == "array" then
            (if ($schema | has("minItems")) and ($value | length) < $schema.minItems then ["\($path) has fewer than minItems"] else [] end)
            + (if ($schema | has("maxItems")) and ($value | length) > $schema.maxItems then ["\($path) has more than maxItems"] else [] end)
            + (if ($schema | has("items")) and (($schema.items | type) != "array")
               then ([ $value | to_entries[] | .key as $i | check($schema.items; .value; "\($path)[\($i)]") ] | add // [])
               else [] end)
          else [] end)
        + (if ($value | type) == "object" then
            ([ ($schema.required // [])[] | select(. as $r | ($value | has($r)) | not) | "\($path).\(.) is required" ])
            + ([ $value | to_entries[] | .key as $k | .value as $child
                 | if (($schema.properties // {}) | has($k)) then check($schema.properties[$k]; $child; "\($path).\($k)")
                   elif $schema.additionalProperties == false then ["\($path).\($k) is not allowed"]
                   elif ($schema.additionalProperties | type) == "object" then check($schema.additionalProperties; $child; "\($path).\($k)")
                   else [] end ] | add // [])
          else [] end)
        + (if ($value | type) == "string" then
            (if ($schema | has("minLength")) and ($value | length) < $schema.minLength then ["\($path) is shorter than minLength"] else [] end)
            + (if ($schema | has("maxLength")) and ($value | length) > $schema.maxLength then ["\($path) is longer than maxLength"] else [] end)
            + (if ($schema | has("pattern")) and (($value | test($schema.pattern)) | not) then ["\($path) does not match pattern"] else [] end)
          else [] end)
        + (if ($value | type) == "number" then
            (if ($schema | has("minimum")) and $value < $schema.minimum then ["\($path) is below minimum"] else [] end)
            + (if ($schema | has("maximum")) and $value > $schema.maximum then ["\($path) is above maximum"] else [] end)
          else [] end)
        + ([ (["allOf", "all"], ["anyOf", "any"], ["oneOf", "one"]) as [$keyword, $mode]
             | select($schema | has($keyword))
             | ([ $schema[$keyword][] | select((check(.; $value; $path) | length) == 0) ] | length) as $matches
             | select(($mode == "all" and $matches != ($schema[$keyword] | length))
                      or ($mode == "any" and $matches == 0)
                      or ($mode == "one" and $matches != 1))
             | "\($path) does not satisfy \($keyword)" ])
        + (if ($schema | has("not")) and ((check($schema.not; $value; $path) | length) == 0) then ["\($path) satisfies forbidden not schema"] else [] end)
      end
  end;

$schema[0] as $s
| . as $v
| (unsupported_keywords($s; "$")) as $errors
| (if ($errors | length) == 0 then check($s; $v; "$") else $errors end)
| .[]
