defmodule Jamdb.Oracle do
  @moduledoc """
  Oracle driver for Elixir.

  It relies on `DBConnection` to provide pooling, prepare, execute and more.

  """
  
  @behaviour DBConnection
  
  @doc """
  Connect to the database. Return `{:ok, pid}` on success or
  `{:error, term}` on failure.

  ## Options

    * `:hostname` - Server hostname (Name or IP address of the database server)
    * `:port` - Server port (Number of the port where the server listens for requests)
    * `:database` - Database (Database service name or SID with colon as prefix)
    * `:username` - Username (Name for the connecting user)
    * `:password` - User password (Password for the connecting user)
    * `:parameters` - Keyword list of connection parameters
    * `:socket_options` - Options to be given to the underlying socket
    * `:timeout` - The default timeout to use on queries, defaults to `15000`

  This callback is called in the connection process.
  """  
  @callback connect(opts :: Keyword.t) :: 
    {:ok, pid} | {:error, term}
  def connect(opts) do
    database = Keyword.fetch!(opts, :database) |> to_charlist
    env = if( hd(database) == ?:, do: [sid: tl(database)], else: [service_name: database] )
    |> Keyword.put_new(:host, Keyword.fetch!(opts, :hostname) |> to_charlist)
    |> Keyword.put_new(:port, Keyword.fetch!(opts, :port))
    |> Keyword.put_new(:user, Keyword.fetch!(opts, :username) |> to_charlist)
    |> Keyword.put_new(:password, Keyword.fetch!(opts, :password) |> to_charlist)
    |> Keyword.put_new(:timeout, Keyword.fetch!(opts, :timeout))
    params = if( Keyword.has_key?(opts, :parameters) == true,
      do: opts[:parameters], else: [] )
    sock_opts = if( Keyword.has_key?(opts, :socket_options) == true,
      do: [socket_options: opts[:socket_options]], else: [] )
    :jamdb_oracle.start_link(sock_opts ++ params ++ env) 
  end

  @doc """
  Disconnect from the database. Return `:ok`.

  This callback is called in the connection process.
  """
  @callback disconnect(err :: term, s :: pid) :: :ok
  def disconnect(_err, s) do
    :jamdb_oracle.stop(s) 
  end

  @doc """
  Runs custom SQL query on given pid.

  In case of success, it must return an `:ok` tuple containing result struct. Its fields are:

    * `:columns` - The column names
    * `:num_rows` - The number of fetched or affected rows
    * `:rows` - The result set as list

  ## Examples

      iex> Jamdb.Oracle.query(s, 'select 1+:1, sysdate, rowid from dual where 1=:1 ',[1])
      {:ok, %{num_rows: 1, rows: [[{2}, {{2016, 8, 1}, {13, 14, 15}}, 'AAAACOAABAAAAWJAAA']]}}

  """
  @callback query(s :: pid, sql :: String.t, params :: [term] | map) :: 
    {:ok, term} | {:error, term}  
  def query(s, sql, params \\ []) do
    case :jamdb_oracle.sql_query(s, {sql, params}) do
      {:ok, [{_, columns, _, rows}]} ->
        {:ok, %{num_rows: length(rows), rows: rows, columns: columns}, s}
      {:ok, [{_, 0, rows}]} -> {:ok, %{num_rows: length(rows), rows: rows}, s}
      {:ok, [{_, code, msg}]} -> {:error, %{code: code, message: msg}, s}
      {:ok, [{_, num_rows}]} -> {:ok, %{num_rows: num_rows, rows: nil}, s}
      {:ok, result} -> {:ok, result, s}
      {:error, _, err} -> {:error, err, s}
    end    
  end
  
  @doc false
  def handle_execute(query, params, opts, s) do
    %Jamdb.Oracle.Query{statement: statement} = query
    returning = Keyword.get(opts, :returning, []) |> Enum.filter(& is_tuple(&1))
    query(s, statement |> to_charlist, Enum.concat(params, returning))
  end

  @doc false
  def handle_prepare(%Jamdb.Oracle.Query{statement: %Jamdb.Oracle.Query{} = query}, opts, s) do
    {:ok, query, s}  
  end
  def handle_prepare(query, opts, s) do
    {:ok, query, s}  
  end

  @doc false
  def handle_begin(opts, s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction -> query(s, 'SAVEPOINT tran')
      :savepoint   -> query(s, 'SAVEPOINT '++(Keyword.get(opts, :name, :svpt) |> to_charlist))
    end  
  end

  @doc false
  def handle_commit(opts, s) do
    query(s, 'COMMIT')
  end

  @doc false
  def handle_rollback(opts, s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction -> query(s, 'ROLLBACK TO tran')
      :savepoint   -> query(s, 'ROLLBACK TO '++(Keyword.get(opts, :name, :svpt) |> to_charlist))      
    end
  end
    
  @doc false
  def handle_prepare(query, opts, s) do 
    {:ok, query, s}
  end

  @doc false
  def handle_declare(query, params, opts, s) do
    {:ok, params, s}
  end

  @doc false
  def handle_first(query, params, opts, s) do
    case handle_execute(query, params, opts, s) do
      {:ok, result, s} -> {:deallocate, result, s}
      {:error, err, s} -> {:error, error!(err), s}
    end
  end

  @doc false
  def handle_next(query, cursor, opts, s) do
    {:deallocate, nil, s}
  end

  @doc false
  def handle_deallocate(query, cursor, opts, s) do
    {:ok, nil, s}
  end
  
  @doc false
  def handle_close(query, opts, s) do
    {:ok, nil, s}
  end

  @doc false
  def handle_info(msg, s) do
    {:ok, s}
  end

  @doc false
  def checkin(s) do
    {:ok, s}
  end

  @doc false
  def checkout(s) do
    {:ok, s}
  end

  @doc false
  def ping(s) do
    case query(s, 'PING') do
      {:ok, _, s} -> {:ok, s}
      disconnect -> disconnect
    end    
  end

  defp error!(msg) do
    DBConnection.ConnectionError.exception("#{inspect msg}")
  end
  
end

defimpl DBConnection.Query, for: Jamdb.Oracle.Query do

  def parse(query, _), do: query
  def describe(query, _), do: query

  def decode(_, %{rows: []} = result, _), do: result
  def decode(_, %{rows: rows} = result, opts) when rows != nil, 
    do: %{result | rows: Enum.map(rows, fn row -> decode(row, opts[:decode_mapper]) end)}  
  def decode(_, result, _), do: result

  defp decode(row, nil), do: Enum.map(row, fn elem -> decode(elem) end)
  defp decode(row, mapper), do: mapper.(decode(row, nil))

  defp decode(:null), do: nil
  defp decode({elem}) when is_number(elem), do: elem
  defp decode({date, {hour, min, sec}}), do: {date, {hour, min, trunc(sec)}}
  defp decode({date, {hour, min, sec}, _}), do: {date, {hour, min, trunc(sec)}}
  defp decode(elem) when is_list(elem), do: to_binary(elem)
  defp decode(elem), do: elem

  def encode(_, [], _), do: []
  def encode(_, params, _), do: Enum.map(params, fn elem -> encode(elem) end)

  defp encode(nil), do: :null
  defp encode(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp encode(%Ecto.Query.Tagged{value: binary, type: :binary}), 
    do: :binary.bin_to_list(Base.encode16(binary, case: :lower))
  defp encode(%Ecto.Query.Tagged{value: elem}), do: elem
  defp encode(elem), do: elem

  defp expr(list) when is_list(list) do
    Enum.map(list, fn 
      :null -> nil
      elem  -> elem
    end)    
  end

  defp to_binary(list) when is_list(list) do
    try do 
      :binary.list_to_bin(list)
    rescue
      ArgumentError ->
        Enum.map(expr(list), fn 
          elem when is_list(elem) -> expr(elem) 
          other -> other
        end) |> Enum.join
    end        
  end

end
