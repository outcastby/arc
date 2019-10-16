defmodule Arc.File do
  defstruct [:path, :file_name, :binary, headers: [], mime_type: nil, ext: nil]

  def generate_temporary_path(file \\ nil) do
    extension = Path.extname((file && file.path) || "")

    file_name =
      :crypto.strong_rand_bytes(20)
      |> Base.encode32()
      |> Kernel.<>(extension)

    Path.join(System.tmp_dir(), file_name)
  end

  # Given a remote file
  def new(remote_path = "http" <> _, scope) do
    uri = URI.parse(remote_path)

    filename =
      case scope do
        %{__meta__: _} -> Path.basename(uri.path)
        _ -> (scope[:file_name] || Path.basename(uri.path)) |> String.downcase()
      end

    case save_file(uri, filename) do
      {:ok, local_path, headers} ->
        {_, mime_type} = Enum.find(headers, fn {a, b} -> String.downcase(a) == "content-type" end)
        {file_name, ext} = get_file_name_and_ext(filename, mime_type)

        %Arc.File{
          path: local_path,
          file_name: file_name,
          headers: headers,
          ext: ext,
          mime_type: mime_type
        }

      :error ->
        {:error, :invalid_file_path}
    end
  end

  def valid_ext_from_filename?(filename) do
    case Path.extname(filename) do
      "." <> ext -> MIME.has_type?(ext)
      _ -> false
    end
  end

  def get_file_name_and_ext(filename, mime_type) do
    case valid_ext_from_filename?(filename) do
      true ->
        "." <> ext = Path.extname(filename)
        {filename, ext}

      false ->
        [ext | _] = MIME.extensions(mime_type)
        {filename <> "." <> ext, ext}
    end
  end

  # Accepts a path
  def new(path, _scope) when is_binary(path) do
    case File.exists?(path) do
      true -> %Arc.File{path: path, file_name: Path.basename(path)}
      false -> {:error, :invalid_file_path}
    end
  end

  def new(%{filename: filename, binary: binary}, _scope) do
    %Arc.File{binary: binary, file_name: Path.basename(filename)}
  end

  # Accepts a map conforming to %Plug.Upload{} syntax
  def new(%{filename: filename, path: path}, _scope) do
    case File.exists?(path) do
      true -> %Arc.File{path: path, file_name: filename}
      false -> {:error, :invalid_file_path}
    end
  end

  def ensure_path(file = %{path: path}) when is_binary(path), do: file
  def ensure_path(file = %{binary: binary}) when is_binary(binary), do: write_binary(file)

  defp write_binary(file) do
    path = generate_temporary_path(file)
    :ok = File.write!(path, file.binary)

    %__MODULE__{
      file_name: file.file_name,
      path: path
    }
  end

  defp save_file(uri, filename) do
    local_path =
      generate_temporary_path()
      |> Kernel.<>(Path.extname(filename))

    case save_temp_file(local_path, uri) do
      {:ok, headers} -> {:ok, local_path, headers}
      _ -> :error
    end
  end

  defp save_temp_file(local_path, remote_path) do
    remote_file = get_remote_path(remote_path)

    case remote_file do
      {:ok, file} ->
        File.write(local_path, file.body)
        {:ok, file.headers}

      {:error, error} ->
        {:error, error}
    end
  end

  # hakney :connect_timeout - timeout used when establishing a connection, in milliseconds
  # hakney :recv_timeout - timeout used when receiving from a connection, in milliseconds
  # poison :timeout - timeout to establish a connection, in milliseconds
  # :backoff_max - maximum backoff time, in milliseconds
  # :backoff_factor - a backoff factor to apply between attempts, in milliseconds
  defp get_remote_path(remote_path) do
    options = [
      follow_redirect: true,
      recv_timeout: Application.get_env(:arc, :recv_timeout, 5_000),
      connect_timeout: Application.get_env(:arc, :connect_timeout, 10_000),
      timeout: Application.get_env(:arc, :timeout, 10_000),
      max_retries: Application.get_env(:arc, :max_retries, 3),
      backoff_factor: Application.get_env(:arc, :backoff_factor, 1000),
      backoff_max: Application.get_env(:arc, :backoff_max, 30_000)
    ]

    request(remote_path, options)
  end

  defp request(remote_path, options, tries \\ 0) do
    case :hackney.get(URI.to_string(remote_path), [], "", options) do
      {:ok, 200, headers, client_ref} ->
        {:ok, body} = :hackney.body(client_ref)
        {:ok, %{body: body, headers: headers}}

      {:error, %{reason: :timeout}} ->
        case retry(tries, options) do
          {:ok, :retry} -> request(remote_path, options, tries + 1)
          {:error, :out_of_tries} -> {:error, :timeout}
        end

      _ ->
        {:error, :arc_httpoison_error}
    end
  end

  defp retry(tries, options) do
    cond do
      tries < options[:max_retries] ->
        backoff = round(options[:backoff_factor] * :math.pow(2, tries - 1))
        backoff = :erlang.min(backoff, options[:backoff_max])
        :timer.sleep(backoff)
        {:ok, :retry}

      true ->
        {:error, :out_of_tries}
    end
  end
end
