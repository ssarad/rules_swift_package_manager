"""Module for Swift file operations."""

def _has_objc_directive(contents):
    """Determines whether the specified file contains any `@objc` or \
    `@objcMembers` directives indicating that the Swift file will be consumed \
    by Objective-C code.

    Args:
        contents: Swift code as a `string`.

    Returns:
        A `bool` indicating whether the string contains an Objective-C directive.
    """
    result = contents.find("@objc")
    return result >= 0

def _find_import(contents, target_import, start_idx = 0):
    contents_len = len(contents)
    target_stmt = "import {}".format(target_import)
    target_stmt_len = len(target_stmt)

    for _ in range(start_idx, contents_len):
        imp_start_idx = contents.find(target_stmt, start_idx)
        if imp_start_idx < 0:
            return None

        # Include the previous char; looking for word boundary
        frag_start = imp_start_idx
        if frag_start > 0:
            frag_start -= 1

        # Include the next char; looking for word boundary
        imp_end_idx = imp_start_idx + target_stmt_len
        start_idx = imp_end_idx
        frag_end = imp_end_idx + 1
        if frag_end > contents_len:
            # We are at the end of the contents
            frag_end -= 1
        fragment = contents[frag_start:frag_end]
        if fragment.strip() == target_stmt:
            return _new_range(start = imp_start_idx, end = imp_end_idx)

    return None

def _new_range(start, end):
    return struct(
        start = start,
        end = end,
    )

def _look_ahead(contents, idx, value):
    look_head_len = len(value)
    look_ahead_idx = idx + look_head_len
    if look_ahead_idx > len(contents):
        return -1
    look_ahead = contents[idx:look_ahead_idx]
    if look_ahead == value:
        return look_ahead_idx
    return -1

_multiline_str_delim = "\"\"\""

def _collect_string_literal(contents, idx):
    # Check for multiline string (""")
    start_idx = _look_ahead(contents, idx, _multiline_str_delim)
    if start_idx >= 0:
        multiline = True
    else:
        multiline = False
        start_idx = idx + 1

    escape = False
    for sidx in range(start_idx, len(contents)):
        char = contents[sidx]
        if char == "\"" and not escape:
            if multiline:
                la_idx = _look_ahead(contents, sidx, _multiline_str_delim)
                if la_idx >= 0:
                    return la_idx
            else:
                return sidx + 1
        elif char == "\\":
            escape = True
        else:
            escape = False

    fail("Did not find the end of the string literal starting at {}.".format(
        idx,
    ))

def _collect_single_line_comment(contents, idx):
    # We know that idx is pointing at //
    start_idx = idx + 2
    for sidx in range(start_idx, len(contents)):
        char = contents[sidx]
        if char == "\n":
            return sidx + 1
    fail("Did not find the end of single line comment starting at {}.".format(
        idx,
    ))

def _collect_multiline_comment(contents, idx):
    # We know that idx is pointing at /*
    start_idx = idx + 2
    for sidx in range(start_idx, len(contents)):
        char = contents[sidx]
        if char == "*":
            la_idx = _look_ahead(contents, sidx, "*/")
            if la_idx >= 0:
                return la_idx
    fail("Did not find the end of multi-line comment starting at {}.".format(
        idx,
    ))

def _collect_conditional_compilation(contents, idx):
    # Conditional compilation blocks can be nested. We will process until
    # block level is at 0.
    block_level = 1

    # We know that idx is pointing at #if
    start_idx = idx + 3
    for sidx in range(start_idx, len(contents)):
        char = contents[sidx]
        if char == "#":
            if _look_ahead(contents, sidx, "#if") >= 0:
                block_level += 1
            else:
                la_idx = _look_ahead(contents, sidx, "#endif")
                if la_idx >= 0:
                    block_level -= 1
                    if block_level == 0:
                        return la_idx

    fail("""\
Did not find the end of the conditional compilation block starting at {}.\
""".format(idx))

def _is_code(contents, target_idx):
    skip_to = -1
    for idx in range(0, len(contents)):
        if skip_to == idx:
            # Need to reset the skip_to before the next check.
            skip_to = -1
        if idx == target_idx:
            # If we are not skipping ahead, then it is a valid code location.
            return skip_to < 0
        if skip_to > idx:
            continue
        elif skip_to >= 0:
            fail("Somehow skip_to is behind. idx: {idx}, skip_to: {skip_to}".format(
                idx = idx,
                skip_to = skip_to,
            ))
        char = contents[idx]
        if char == "\"":
            skip_to = _collect_string_literal(contents, idx)
        elif char == "/":
            if _look_ahead(contents, idx, "//") >= 0:
                skip_to = _collect_single_line_comment(contents, idx)
            elif _look_ahead(contents, idx, "/*") >= 0:
                skip_to = _collect_multiline_comment(contents, idx)
        elif char == "#":
            if _look_ahead(contents, idx, "#if") >= 0:
                skip_to = _collect_conditional_compilation(contents, idx)

    return False

def _has_import(contents, target_import):
    """Determines whether a string contains a Swift import statement for module.

    Args:
        contents: A `string` value to be evaluated.
        target_import: The name of the imported module as a `string`.

    Returns:
        A `bool` indicating whether an import statement for the module was found.
    """
    start_idx = 0
    for _ in range(len(contents)):
        import_range = _find_import(contents, target_import, start_idx = start_idx)
        if import_range == None:
            return False
        if _is_code(contents, import_range.start):
            return True
        start_idx = import_range.end
    return False

def _is_identifier_char(char):
    return (("a" <= char and char <= "z") or ("A" <= char and char <= "Z") or ("0" <= char and char <= "9") or char == "_")

def _has_closing_bare_regex(contents, start):
    """Checks for an unescaped closing slash before the next line break."""
    escaped = False
    for idx in range(start + 1, len(contents)):
        char = contents[idx]
        if char == "\n":
            return False
        if char == "/" and not escaped:
            return True
        if char == "\\":
            escaped = not escaped
        else:
            escaped = False
    return False

def _masked_swift_source(contents):
    """Replaces comments and string literals with spaces, preserving newlines."""
    result = []
    skip_to = 0
    comment_depth = 0
    string_closing = None
    interpolation_depth = 0
    interpolation_stack = []
    for idx in range(len(contents)):
        char = contents[idx]
        pair = contents[idx:idx + 2]
        if idx < skip_to:
            continue
        if comment_depth:
            if pair == "/*":
                comment_depth += 1
                result.extend([" ", " "])
                skip_to = idx + 2
            elif pair == "*/":
                comment_depth -= 1
                result.extend([" ", " "])
                skip_to = idx + 2
            else:
                result.append("\n" if char == "\n" else " ")
        elif string_closing != None:
            if contents[idx:idx + len(string_closing)] == string_closing:
                result.extend([" "] * len(string_closing))
                skip_to = idx + len(string_closing)
                string_closing = None
            elif char == "\\" and idx + 1 < len(contents):
                hashes = 0 if string_closing.startswith("/") else string_closing.count("#")
                escape_len = 1 + hashes
                if contents[idx + 1:idx + escape_len] == "#" * hashes and idx + escape_len < len(contents):
                    for escaped_idx in range(idx, idx + escape_len + 1):
                        result.append("\n" if contents[escaped_idx] == "\n" else " ")
                    skip_to = idx + escape_len + 1
                    if contents[idx + escape_len] == "(" and not string_closing.startswith("/"):
                        interpolation_stack.append((string_closing, interpolation_depth))
                        string_closing = None
                        interpolation_depth = 1
                else:
                    result.append(" ")
            else:
                result.append("\n" if char == "\n" else " ")
        elif pair == "//":
            end = contents.find("\n", idx)
            if end < 0:
                end = len(contents)
            result.extend([" "] * (end - idx))
            skip_to = end
        elif pair == "/*":
            comment_depth = 1
            result.extend([" ", " "])
            skip_to = idx + 2
        elif interpolation_depth and char == "(":
            interpolation_depth += 1
            result.append(" ")
        elif interpolation_depth and char == ")":
            interpolation_depth -= 1
            result.append(" ")
            if interpolation_depth == 0:
                string_closing, interpolation_depth = interpolation_stack.pop()
        elif char == '"' or char == "#" or char == "/":
            # A raw string has one or more hashes immediately before its quote.
            hashes = 0
            if char == "#":
                for hidx in range(idx, len(contents)):
                    if contents[hidx] != "#":
                        break
                    hashes += 1
            quote_idx = idx + hashes
            if quote_idx < len(contents) and contents[quote_idx] == '"':
                triple = contents[quote_idx:quote_idx + 3] == '"""'
                opening = hashes + (3 if triple else 1)
                string_closing = ('"""' if triple else '"') + "#" * hashes
                result.extend([" "] * opening)
                skip_to = idx + opening
            elif quote_idx < len(contents) and contents[quote_idx] == "/" and (hashes or (char == "/" and idx + 1 < len(contents) and contents[idx + 1] not in " \t\r\n/*" and (idx == 0 or contents[idx - 1] in " \t\r\n=(:,[") and _has_closing_bare_regex(contents, idx))):
                string_closing = "/" + "#" * hashes
                result.extend([" "] * (hashes + 1))
                skip_to = idx + hashes + 1
            else:
                result.append(" " if interpolation_depth else char)
        else:
            result.append(" " if interpolation_depth else char)
    return "".join(result)

def _collect_imports(contents):
    """Collects lexical Swift imports from all conditional compilation branches.

    Each result has `module_name`, 1-based `line_number`, and `is_conditional`.
    This does not evaluate compilation conditions or resolve SDK modules. Bare
    slash regexes are recognized only in common expression-start contexts;
    this is a lexical scan, not a full Swift parser.
    """
    masked = _masked_swift_source(contents)
    imports = []
    conditional_depth = 0
    line_start = 0
    for line_idx, line in enumerate(masked.split("\n")):
        line_number = line_idx + 1
        current_line_start = line_start
        line_start += len(line) + 1
        stripped = line.strip()
        if stripped.startswith("#if") and (len(stripped) == 3 or not _is_identifier_char(stripped[3])):
            conditional_depth += 1
            continue
        if stripped.startswith("#endif"):
            conditional_depth -= 1
            continue
        if stripped.startswith("#elseif") or stripped.startswith("#else"):
            continue
        for start in range(len(line)):
            if line[start:start + 6] != "import":
                continue
            end = start + len("import")
            if (start > 0 and _is_identifier_char(line[start - 1])) or (end < len(line) and _is_identifier_char(line[end])):
                continue
            if current_line_start + end >= len(masked) or masked[current_line_start + end] not in " \t\r\n":
                continue
            module = _import_module_after(masked, current_line_start + end)
            if module != None:
                imports.append(struct(
                    module_name = module,
                    line_number = line_number,
                    is_conditional = conditional_depth > 0,
                ))
    return imports

def _import_module_after(contents, start):
    """Reads the root module after an import keyword in masked source."""
    next_idx = len(contents)
    for idx in range(start, len(contents)):
        if contents[idx] not in " \t\r\n":
            next_idx = idx
            break
    if next_idx == len(contents):
        return None
    words = []
    for _ in range(2):
        if next_idx >= len(contents):
            break
        if contents[next_idx] == "`":
            close = contents.find("`", next_idx + 1)
            if close < 0:
                break
            words.append(contents[next_idx + 1:close])
            next_idx = close + 1
        else:
            word_end = next_idx
            for idx in range(next_idx, len(contents)):
                if not _is_identifier_char(contents[idx]):
                    break
                word_end = idx + 1
            if word_end == next_idx:
                break
            words.append(contents[next_idx:word_end])
            next_idx = word_end
        if words[0] not in ["typealias", "struct", "class", "enum", "protocol", "let", "var", "func"]:
            break
        for idx in range(next_idx, len(contents)):
            if contents[idx] not in " \t\r\n":
                next_idx = idx
                break
    if len(words) == 2:
        return words[1]
    if words and words[0] not in ["typealias", "struct", "class", "enum", "protocol", "let", "var", "func"]:
        return words[0]
    return None

swift_files = struct(
    collect_imports = _collect_imports,
    has_import = _has_import,
    has_objc_directive = _has_objc_directive,
)
