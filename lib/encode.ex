defmodule Jason.EncodeError do
  defexception [:message]

  @type t :: %__MODULE__{message: String.t}

  def new({:duplicate_key, key}) do
    %__MODULE__{message: "duplicate key: #{key}"}
  end
  def new({:invalid_byte, byte, original}) do
    %__MODULE__{message: "invalid byte #{inspect byte, base: :hex} in #{inspect original}"}
  end
end

defmodule Jason.Encode do
  @moduledoc """
  Utilities for encoding elixir values to JSON.
  """

  import Bitwise

  alias Jason.{Codegen, EncodeError, Encoder, Fragment, OrderedObject}

  @type extra_opts :: map()
  @type escape :: (String.t, String.t, integer -> iodata)
  @type encode_map :: (map, escape, encode_map, extra_opts -> iodata)
  @type opts :: {escape, encode_map} | {escape, encode_map, extra_opts}

  @dialyzer :no_improper_lists

  # @compile :native

  @doc false
  @spec encode(any, map) :: {:ok, iodata} | {:error, EncodeError.t | Exception.t}
  def encode(value, opts) do
    escape = escape_function(opts)
    encode_map = encode_map_function(opts)
    opts1 = Map.drop opts, [:maps, :escape, :compact]
    try do
      r = value(value, escape, encode_map, opts1)
      r = if Map.get(opts, :compact), do: compact(r), else: r
      {:ok, r}
    catch
      :throw, %EncodeError{} = e ->
        {:error, e}
      :error, %Protocol.UndefinedError{protocol: Jason.Encoder} = e ->
        {:error, e}
    end
  end

  def compact(nil), do: "null"
  def compact(["{\"" | _] = map), do: compact_map(map, [])
  def compact([?[ | _] = list), do: compact_list(list, [])
  def compact(val), do: val

  defp compact_map([?}], []), do: "{}"
  defp compact_map([?}], acc), do: [?} | acc] |> Enum.reverse
  defp compact_map([sep, name, "\":", val | rest], acc) when sep in ["{\"", ",\""] do
    c_val = compact(val)
    sep = case acc do
      [] -> "{\""
      _ -> sep
    end
    acc1 =
      case val_empty(c_val) do
        true -> acc
        _ -> [[sep, name, "\":", c_val] | acc]
      end
      compact_map(rest, acc1)
  end

  defp compact_list([?]], []), do: "[]"
  defp compact_list([?]], acc), do: [?] | acc] |> Enum.reverse
  defp compact_list([sep, val | rest], acc) when sep in [?[, ?,] do
    c_val = compact(val)
    sep = case acc do
      [] -> ?[
      _ -> sep
    end
    acc1 =
      case val_empty(c_val) do
        true -> acc
        _ -> [c_val, sep | acc]
      end
    compact_list(rest, acc1)
  end

  defp val_empty([]), do: true
  defp val_empty("null"), do: true
  # defp val_empty("[]"), do: true
  defp val_empty("{}"), do: true
  defp val_empty(_v), do: false


  defp encode_map_function(%{maps: maps}) do
    case maps do
      :naive -> &map_naive/4
      :strict -> &map_strict/4
    end
  end

  defp escape_function(%{escape: escape}) do
    case escape do
      :json -> &escape_json/3
      :html_safe -> &escape_html/3
      :unicode_safe -> &escape_unicode/3
      :javascript_safe -> &escape_javascript/3
      # Keep for compatibility with Poison
      :javascript -> &escape_javascript/3
      :unicode -> &escape_unicode/3
    end
  end

  @doc """
  Equivalent to calling the `Jason.Encoder.encode/2` protocol function1.

  Slightly more efficient for built-in types because of the internal dispatching.
  """
  @spec value(term, opts) :: iodata
  @dialyzer {:nowarn_function, value: 2}
  def value(value, {escape, encode_map}) do
    value(value, escape, encode_map)
  end

  def value(value, {escape, encode_map, extra_opts}) do
    value(value, escape, encode_map, extra_opts)
  end

  @doc false
  # We use this directly in the helpers and deriving for extra speed
  def value(value, escape, encode_map, opts \\ %{})
  def value(value, escape, _encode_map, _opts) when is_atom(value) do
    encode_atom(value, escape)
  end

  def value(value, escape, _encode_map, _opts) when is_binary(value) do
    encode_string(value, escape)
  end

  def value(value, _escape, _encode_map, _opts) when is_integer(value) do
    integer(value)
  end

  def value(value, _escape, _encode_map, _opts) when is_float(value) do
    float(value)
  end

  def value([{}], _escape, _encode_map, _opts), do: "{}"
  def value([{_, _} | _] = keyword, escape, encode_map, opts) do
    encode_map.(keyword, escape, encode_map, opts)
  end

  def value(value, escape, encode_map, opts) when is_list(value) do
    list(value, escape, encode_map, opts)
  end

  def value(%{__struct__: module} = value, escape, encode_map, opts) do
    struct(value, escape, encode_map, module, opts)
  end

  def value(value, escape, encode_map, opts) when is_map(value) do
    case Map.to_list(value) do
      [] -> "{}"
      keyword -> encode_map.(keyword, escape, encode_map, opts)
    end
  end

  def value(value, escape, encode_map, opts) when opts == %{} do
    Encoder.encode(value, {escape, encode_map})
  end

  def value(value, escape, encode_map, opts) do
    Encoder.encode(value, {escape, encode_map, opts})
  end

  @compile {:inline, integer: 1, float: 1}

  @spec atom(atom, opts) :: iodata
  def atom(atom, {escape, _encode_map}) do
    encode_atom(atom, escape)
  end

  defp encode_atom(nil, _escape), do: "null"
  defp encode_atom(true, _escape), do: "true"
  defp encode_atom(false, _escape), do: "false"
  defp encode_atom(atom, escape),
    do: encode_string(Atom.to_string(atom), escape)

  @spec integer(integer) :: iodata
  def integer(integer) do
    Integer.to_string(integer)
  end

  has_short_format = try do
    :erlang.float_to_binary(1.0, [:short])
  catch
    _, _ -> false
  else
    _ -> true
  end

  @spec float(float) :: iodata
  if has_short_format do
    def float(float) do
      :erlang.float_to_binary(float, [:short])
    end
  else
    def float(float) do
      :io_lib_format.fwrite_g(float)
   end
  end

  @spec list(list, opts) :: iodata
  def list(list, {escape, encode_map}) do
    list(list, escape, encode_map)
  end

  def list(list, {escape, encode_map, opts}) do
    list(list, escape, encode_map, opts)
  end

  defp list(list, escape, encode_map, opts \\ %{})

  defp list([], _escape, _encode_map, _opts) do
    "[]"
  end

  defp list([head | tail], escape, encode_map, opts) do
    [?[, value(head, escape, encode_map, opts)
     | list_loop(tail, escape, encode_map, opts)]
  end

  defp list_loop([], _escape, _encode_map, _opts) do
    ']'
  end

  defp list_loop([head | tail], escape, encode_map, opts) do
    [?,, value(head, escape, encode_map, opts)
     | list_loop(tail, escape, encode_map, opts)]
  end

  @spec keyword(keyword, opts) :: iodata
  def keyword(list, _) when list == [], do: "{}"
  def keyword(list, {escape, encode_map}) when is_list(list) do
    keyword(list, {escape, encode_map, %{}})
  end
  def keyword(list, {escape, encode_map, opts}) when is_list(list) do
    encode_map.(list, escape, encode_map, opts)
  end

  @spec map(map, opts) :: iodata
  def map(value, {escape, encode_map}) do
    map(value, {escape, encode_map, %{}})
  end
  def map(value, {escape, encode_map, opts}) do
    case Map.to_list(value) do
      [] -> "{}"
      keyword -> encode_map.(keyword, escape, encode_map, opts)
    end
  end

  defp map_naive([{key, value} | tail], escape, encode_map, opts) do
    ["{\"", key(key, escape), "\":",
    value(value, escape, encode_map, opts)
    | map_naive_loop(tail, escape, encode_map, opts)]
  end

  defp map_naive_loop([], _escape, _encode_map, _opts) do
    '}'
  end

  defp map_naive_loop([{key, value} | tail], escape, encode_map, opts) do
    [",\"", key(key, escape), "\":",
     value(value, escape, encode_map, opts)
     | map_naive_loop(tail, escape, encode_map, opts)]
  end

  defp map_strict([{key, value} | tail], escape, encode_map, opts) do
    key = IO.iodata_to_binary(key(key, escape))
    visited = %{key => []}
    ["{\"", key, "\":",
     value(value, escape, encode_map, opts)
     | map_strict_loop(tail, escape, encode_map, visited, opts)]
  end

  defp map_strict_loop([], _encode_map, _escape, _visited, _opts) do
    '}'
  end

  defp map_strict_loop([{key, value} | tail], escape, encode_map, visited, opts) do
    key = IO.iodata_to_binary(key(key, escape))
    case visited do
      %{^key => _} ->
        error({:duplicate_key, key})
      _ ->
        visited = Map.put(visited, key, [])
        [",\"", key, "\":",
         value(value, escape, encode_map, opts)
         | map_strict_loop(tail, escape, encode_map, visited, opts)]
    end
  end

  @spec struct(struct, opts) :: iodata
  def struct(%module{} = value, {escape, encode_map}) do
    struct(value, escape, encode_map, module)
  end

  def struct(%module{} = value, {escape, encode_map, opts}) do
    struct(value, escape, encode_map, module, opts)
  end

  defp struct(value, escape, encode_map, module, opts \\ %{})

  # TODO: benchmark the effect of inlining the to_iso8601 functions
  for module <- [Date, Time, NaiveDateTime, DateTime] do
    defp struct(value, _escape, _encode_map, unquote(module), _opts) do
      [?", unquote(module).to_iso8601(value), ?"]
    end
  end

  defp struct(value, _escape, _encode_map, Decimal, _opts) do
    # silence the xref warning
    decimal = Decimal
    [?", decimal.to_string(value, :normal), ?"]
  end

  defp struct(value, escape, encode_map, Fragment, _opts) do
    %{encode: encode} = value
    encode.({escape, encode_map})
  end

  defp struct(value, escape, encode_map, OrderedObject, opts) do
    case value do
      %{values: []} -> "{}"
      %{values: values} -> encode_map.(values, escape, encode_map, opts)
    end
  end

  defp struct(value, escape, encode_map, _module, opts) when opts == %{} do
    Encoder.encode(value, {escape, encode_map})
  end

  defp struct(value, escape, encode_map, _module, opts) do
    Encoder.encode(value, {escape, encode_map, opts})
  end

  @doc false
  # This is used in the helpers and deriving implementation
  def key(string, escape) when is_binary(string) do
    escape.(string, string, 0)
  end
  def key(atom, escape) when is_atom(atom) do
    string = Atom.to_string(atom)
    escape.(string, string, 0)
  end
  def key(other, escape) do
    string = String.Chars.to_string(other)
    escape.(string, string, 0)
  end

  @spec string(String.t, opts) :: iodata
  def string(string, {escape, _encode_map}) do
    encode_string(string, escape)
  end

  defp encode_string(string, escape) do
    [?", escape.(string, string, 0), ?"]
  end

  slash_escapes = Enum.zip('\b\t\n\f\r\"\\', 'btnfr"\\')
  surogate_escapes = Enum.zip([0x2028, 0x2029], ["\\u2028", "\\u2029"])
  ranges = [{0x00..0x1F, :unicode} | slash_escapes]
  html_ranges = [{0x00..0x1F, :unicode}, {?<, :unicode}, {?/, ?/} | slash_escapes]
  escape_jt = Codegen.jump_table(html_ranges, :error)

  Enum.each(escape_jt, fn
    {byte, :unicode} ->
      sequence = List.to_string(:io_lib.format("\\u~4.16.0B", [byte]))
      defp escape(unquote(byte)), do: unquote(sequence)
    {byte, char} when is_integer(char) ->
      defp escape(unquote(byte)), do: unquote(<<?\\, char>>)
    {byte, :error} ->
      defp escape(unquote(byte)), do: throw(:error)
  end)

  ## regular JSON escape

  json_jt = Codegen.jump_table(ranges, :chunk, 0x7F + 1)

  defp escape_json(data, original, skip) do
    escape_json(data, [], original, skip)
  end

  Enum.map(json_jt, fn
    {byte, :chunk} ->
      defp escape_json(<<byte, rest::bits>>, acc, original, skip)
           when byte === unquote(byte) do
        escape_json_chunk(rest, acc, original, skip, 1)
      end
    {byte, _escape} ->
      defp escape_json(<<byte, rest::bits>>, acc, original, skip)
           when byte === unquote(byte) do
        acc = [acc | escape(byte)]
        escape_json(rest, acc, original, skip + 1)
      end
  end)
  defp escape_json(<<char::utf8, rest::bits>>, acc, original, skip)
       when char <= 0x7FF do
    escape_json_chunk(rest, acc, original, skip, 2)
  end
  defp escape_json(<<char::utf8, rest::bits>>, acc, original, skip)
       when char <= 0xFFFF do
    escape_json_chunk(rest, acc, original, skip, 3)
  end
  defp escape_json(<<_char::utf8, rest::bits>>, acc, original, skip) do
    escape_json_chunk(rest, acc, original, skip, 4)
  end
  defp escape_json(<<>>, acc, _original, _skip) do
    acc
  end
  defp escape_json(<<byte, _rest::bits>>, _acc, original, _skip) do
    error({:invalid_byte, byte, original})
  end

  Enum.map(json_jt, fn
    {byte, :chunk} ->
      defp escape_json_chunk(<<byte, rest::bits>>, acc, original, skip, len)
           when byte === unquote(byte) do
        escape_json_chunk(rest, acc, original, skip, len + 1)
      end
    {byte, _escape} ->
      defp escape_json_chunk(<<byte, rest::bits>>, acc, original, skip, len)
           when byte === unquote(byte) do
        part = binary_part(original, skip, len)
        acc = [acc, part | escape(byte)]
        escape_json(rest, acc, original, skip + len + 1)
      end
  end)
  defp escape_json_chunk(<<char::utf8, rest::bits>>, acc, original, skip, len)
       when char <= 0x7FF do
    escape_json_chunk(rest, acc, original, skip, len + 2)
  end
  defp escape_json_chunk(<<char::utf8, rest::bits>>, acc, original, skip, len)
       when char <= 0xFFFF do
    escape_json_chunk(rest, acc, original, skip, len + 3)
  end
  defp escape_json_chunk(<<_char::utf8, rest::bits>>, acc, original, skip, len) do
    escape_json_chunk(rest, acc, original, skip, len + 4)
  end
  defp escape_json_chunk(<<>>, acc, original, skip, len) do
    part = binary_part(original, skip, len)
    [acc | part]
  end
  defp escape_json_chunk(<<byte, _rest::bits>>, _acc, original, _skip, _len) do
    error({:invalid_byte, byte, original})
  end

  ## javascript safe JSON escape

  defp escape_javascript(data, original, skip) do
    escape_javascript(data, [], original, skip)
  end

  Enum.map(json_jt, fn
    {byte, :chunk} ->
      defp escape_javascript(<<byte, rest::bits>>, acc, original, skip)
            when byte === unquote(byte) do
        escape_javascript_chunk(rest, acc, original, skip, 1)
      end
    {byte, _escape} ->
      defp escape_javascript(<<byte, rest::bits>>, acc, original, skip)
            when byte === unquote(byte) do
        acc = [acc | escape(byte)]
        escape_javascript(rest, acc, original, skip + 1)
      end
  end)
  defp escape_javascript(<<char::utf8, rest::bits>>, acc, original, skip)
        when char <= 0x7FF do
    escape_javascript_chunk(rest, acc, original, skip, 2)
  end
  Enum.map(surogate_escapes, fn {byte, escape} ->
    defp escape_javascript(<<unquote(byte)::utf8, rest::bits>>, acc, original, skip) do
      acc = [acc | unquote(escape)]
      escape_javascript(rest, acc, original, skip + 3)
    end
  end)
  defp escape_javascript(<<char::utf8, rest::bits>>, acc, original, skip)
        when char <= 0xFFFF do
    escape_javascript_chunk(rest, acc, original, skip, 3)
  end
  defp escape_javascript(<<_char::utf8, rest::bits>>, acc, original, skip) do
    escape_javascript_chunk(rest, acc, original, skip, 4)
  end
  defp escape_javascript(<<>>, acc, _original, _skip) do
    acc
  end
  defp escape_javascript(<<byte, _rest::bits>>, _acc, original, _skip) do
    error({:invalid_byte, byte, original})
  end

  Enum.map(json_jt, fn
    {byte, :chunk} ->
      defp escape_javascript_chunk(<<byte, rest::bits>>, acc, original, skip, len)
            when byte === unquote(byte) do
        escape_javascript_chunk(rest, acc, original, skip, len + 1)
      end
    {byte, _escape} ->
      defp escape_javascript_chunk(<<byte, rest::bits>>, acc, original, skip, len)
            when byte === unquote(byte) do
        part = binary_part(original, skip, len)
        acc = [acc, part | escape(byte)]
        escape_javascript(rest, acc, original, skip + len + 1)
      end
  end)
  defp escape_javascript_chunk(<<char::utf8, rest::bits>>, acc, original, skip, len)
        when char <= 0x7FF do
    escape_javascript_chunk(rest, acc, original, skip, len + 2)
  end
  Enum.map(surogate_escapes, fn {byte, escape} ->
    defp escape_javascript_chunk(<<unquote(byte)::utf8, rest::bits>>, acc, original, skip, len) do
      part = binary_part(original, skip, len)
      acc = [acc, part | unquote(escape)]
      escape_javascript(rest, acc, original, skip + len + 3)
    end
  end)
  defp escape_javascript_chunk(<<char::utf8, rest::bits>>, acc, original, skip, len)
        when char <= 0xFFFF do
    escape_javascript_chunk(rest, acc, original, skip, len + 3)
  end
  defp escape_javascript_chunk(<<_char::utf8, rest::bits>>, acc, original, skip, len) do
    escape_javascript_chunk(rest, acc, original, skip, len + 4)
  end
  defp escape_javascript_chunk(<<>>, acc, original, skip, len) do
    part = binary_part(original, skip, len)
    [acc | part]
  end
  defp escape_javascript_chunk(<<byte, _rest::bits>>, _acc, original, _skip, _len) do
    error({:invalid_byte, byte, original})
  end

  ## HTML safe JSON escape

  html_jt = Codegen.jump_table(html_ranges, :chunk, 0x7F + 1)

  defp escape_html(data, original, skip) do
    escape_html(data, [], original, skip)
  end

  Enum.map(html_jt, fn
    {byte, :chunk} ->
      defp escape_html(<<byte, rest::bits>>, acc, original, skip)
            when byte === unquote(byte) do
        escape_html_chunk(rest, acc, original, skip, 1)
      end
    {byte, _escape} ->
      defp escape_html(<<byte, rest::bits>>, acc, original, skip)
            when byte === unquote(byte) do
        acc = [acc | escape(byte)]
        escape_html(rest, acc, original, skip + 1)
      end
  end)
  defp escape_html(<<char::utf8, rest::bits>>, acc, original, skip)
        when char <= 0x7FF do
    escape_html_chunk(rest, acc, original, skip, 2)
  end
  Enum.map(surogate_escapes, fn {byte, escape} ->
    defp escape_html(<<unquote(byte)::utf8, rest::bits>>, acc, original, skip) do
      acc = [acc | unquote(escape)]
      escape_html(rest, acc, original, skip + 3)
    end
  end)
  defp escape_html(<<char::utf8, rest::bits>>, acc, original, skip)
        when char <= 0xFFFF do
    escape_html_chunk(rest, acc, original, skip, 3)
  end
  defp escape_html(<<_char::utf8, rest::bits>>, acc, original, skip) do
    escape_html_chunk(rest, acc, original, skip, 4)
  end
  defp escape_html(<<>>, acc, _original, _skip) do
    acc
  end
  defp escape_html(<<byte, _rest::bits>>, _acc, original, _skip) do
    error({:invalid_byte, byte, original})
  end

  Enum.map(html_jt, fn
    {byte, :chunk} ->
      defp escape_html_chunk(<<byte, rest::bits>>, acc, original, skip, len)
            when byte === unquote(byte) do
        escape_html_chunk(rest, acc, original, skip, len + 1)
      end
    {byte, _escape} ->
      defp escape_html_chunk(<<byte, rest::bits>>, acc, original, skip, len)
            when byte === unquote(byte) do
        part = binary_part(original, skip, len)
        acc = [acc, part | escape(byte)]
        escape_html(rest, acc, original, skip + len + 1)
      end
  end)
  defp escape_html_chunk(<<char::utf8, rest::bits>>, acc, original, skip, len)
        when char <= 0x7FF do
    escape_html_chunk(rest, acc, original, skip, len + 2)
  end
  Enum.map(surogate_escapes, fn {byte, escape} ->
    defp escape_html_chunk(<<unquote(byte)::utf8, rest::bits>>, acc, original, skip, len) do
      part = binary_part(original, skip, len)
      acc = [acc, part | unquote(escape)]
      escape_html(rest, acc, original, skip + len + 3)
    end
  end)
  defp escape_html_chunk(<<char::utf8, rest::bits>>, acc, original, skip, len)
        when char <= 0xFFFF do
    escape_html_chunk(rest, acc, original, skip, len + 3)
  end
  defp escape_html_chunk(<<_char::utf8, rest::bits>>, acc, original, skip, len) do
    escape_html_chunk(rest, acc, original, skip, len + 4)
  end
  defp escape_html_chunk(<<>>, acc, original, skip, len) do
    part = binary_part(original, skip, len)
    [acc | part]
  end
  defp escape_html_chunk(<<byte, _rest::bits>>, _acc, original, _skip, _len) do
    error({:invalid_byte, byte, original})
  end

  ## unicode escape

  defp escape_unicode(data, original, skip) do
    escape_unicode(data, [], original, skip)
  end

  Enum.map(json_jt, fn
    {byte, :chunk} ->
      defp escape_unicode(<<byte, rest::bits>>, acc, original, skip)
           when byte === unquote(byte) do
        escape_unicode_chunk(rest, acc, original, skip, 1)
      end
    {byte, _escape} ->
      defp escape_unicode(<<byte, rest::bits>>, acc, original, skip)
           when byte === unquote(byte) do
        acc = [acc | escape(byte)]
        escape_unicode(rest, acc, original, skip + 1)
      end
  end)
  defp escape_unicode(<<char::utf8, rest::bits>>, acc, original, skip)
       when char <= 0xFF do
    acc = [acc, "\\u00" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + 2)
  end
  defp escape_unicode(<<char::utf8, rest::bits>>, acc, original, skip)
        when char <= 0x7FF do
    acc = [acc, "\\u0" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + 2)
  end
  defp escape_unicode(<<char::utf8, rest::bits>>, acc, original, skip)
        when char <= 0xFFF do
    acc = [acc, "\\u0" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + 3)
  end
  defp escape_unicode(<<char::utf8, rest::bits>>, acc, original, skip)
        when char <= 0xFFFF do
    acc = [acc, "\\u" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + 3)
  end
  defp escape_unicode(<<char::utf8, rest::bits>>, acc, original, skip) do
    char = char - 0x10000
    acc =
      [
        acc,
        "\\uD", Integer.to_string(0x800 ||| (char >>> 10), 16),
        "\\uD" | Integer.to_string(0xC00 ||| (char &&& 0x3FF), 16)
      ]
    escape_unicode(rest, acc, original, skip + 4)
  end
  defp escape_unicode(<<>>, acc, _original, _skip) do
    acc
  end
  defp escape_unicode(<<byte, _rest::bits>>, _acc, original, _skip) do
    error({:invalid_byte, byte, original})
  end

  Enum.map(json_jt, fn
    {byte, :chunk} ->
      defp escape_unicode_chunk(<<byte, rest::bits>>, acc, original, skip, len)
            when byte === unquote(byte) do
        escape_unicode_chunk(rest, acc, original, skip, len + 1)
      end
    {byte, _escape} ->
      defp escape_unicode_chunk(<<byte, rest::bits>>, acc, original, skip, len)
            when byte === unquote(byte) do
        part = binary_part(original, skip, len)
        acc = [acc, part | escape(byte)]
        escape_unicode(rest, acc, original, skip + len + 1)
      end
  end)
  defp escape_unicode_chunk(<<char::utf8, rest::bits>>, acc, original, skip, len)
       when char <= 0xFF do
    part = binary_part(original, skip, len)
    acc = [acc, part, "\\u00" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + len + 2)
  end
  defp escape_unicode_chunk(<<char::utf8, rest::bits>>, acc, original, skip, len)
        when char <= 0x7FF do
    part = binary_part(original, skip, len)
    acc = [acc, part, "\\u0" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + len + 2)
  end
  defp escape_unicode_chunk(<<char::utf8, rest::bits>>, acc, original, skip, len)
        when char <= 0xFFF do
    part = binary_part(original, skip, len)
    acc = [acc, part, "\\u0" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + len + 3)
  end
  defp escape_unicode_chunk(<<char::utf8, rest::bits>>, acc, original, skip, len)
        when char <= 0xFFFF do
    part = binary_part(original, skip, len)
    acc = [acc, part, "\\u" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + len + 3)
  end
  defp escape_unicode_chunk(<<char::utf8, rest::bits>>, acc, original, skip, len) do
    char = char - 0x10000
    part = binary_part(original, skip, len)
    acc =
      [
        acc, part,
        "\\uD", Integer.to_string(0x800 ||| (char >>> 10), 16),
        "\\uD" | Integer.to_string(0xC00 ||| (char &&& 0x3FF), 16)
      ]
    escape_unicode(rest, acc, original, skip + len + 4)
  end
  defp escape_unicode_chunk(<<>>, acc, original, skip, len) do
    part = binary_part(original, skip, len)
    [acc | part]
  end
  defp escape_unicode_chunk(<<byte, _rest::bits>>, _acc, original, _skip, _len) do
    error({:invalid_byte, byte, original})
  end

  @compile {:inline, error: 1}
  defp error(error) do
    throw EncodeError.new(error)
  end
end
