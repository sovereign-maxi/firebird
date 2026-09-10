defmodule FireBird.Lnurl do
  @moduledoc """
  Payer-side of LUD-06 / LUD-16 (Lightning Address). Given a
  `"user@domain"` address, resolves the LNURL-pay endpoint and
  fetches a fresh bolt11 invoice for a target amount.

  The output is a bolt11 string — the caller's payment path pays
  it through the existing `pay_invoice` flow. This keeps
  LN-address payments identical in trust model to plain bolt11
  payments (payment hash known at submit, preimage validation
  armed, retry-same-invoice safety via LN atomicity).

  ## SSRF hardening

  The address is caller-supplied and untrusted, so every outbound
  step is hardened:

    * HTTPS only.
    * DNS resolved once at request time; every returned IP is
      checked against the private/loopback/link-local blocklist
      (RFC1918, 127/8, 169.254/16, ::1, fc00::/7, fe80::/10)
      before any TCP connect.
    * Max 2 redirects; each redirect target is re-resolved and
      re-validated against the same blocklist.
    * 64 KiB response body cap.
    * 3s connect / 5s total timeout budget.

  Residual risk: DNS rebinding between our IP check and Finch's
  connect. Blast radius is bounded (attacker's response must
  parse as LNURL-pay JSON, then produce a valid bolt11). Follow-
  up: pinned-IP connect via Mint transport_opts. Tracked
  separately from the main push-payment implementation.

  ## Response contract

  On success, `fetch_invoice/3` returns `{:ok, %{bolt11: ...,
  payment_hash: <32-byte binary>, callback_url: ...}}`. The
  caller (typically `FireBird.Executor`) then submits that
  bolt11 through the standard payment path. `payment_hash` is
  extracted from the bolt11 so `ln_payment_hash` can be bound
  on the `%Payment{}` before `mark_succeeded/4` accepts a
  preimage — proof-of-payment validation applies to push
  payments too, not just plain bolt11.
  """

  alias FireBird.Bolt11

  require Logger

  @type ln_address :: String.t()

  @type resolved :: %{
          bolt11: String.t(),
          payment_hash: binary(),
          callback_url: String.t()
        }

  @max_redirects 2
  @max_response_bytes 65_536
  @connect_timeout_ms 3_000
  @total_timeout_ms 5_000

  @doc """
  Parses `"user@domain"` and returns the LNURL-pay well-known URL.
  """
  @spec well_known_url(ln_address()) :: {:ok, String.t()} | {:error, atom()}
  def well_known_url(ln_address) when is_binary(ln_address) do
    case String.split(ln_address, "@", parts: 2) do
      [local, domain]
      when byte_size(local) > 0 and byte_size(domain) > 0 ->
        cond do
          not valid_local?(local) -> {:error, :malformed_local}
          not valid_domain?(domain) -> {:error, :malformed_domain}
          true -> {:ok, "https://#{domain}/.well-known/lnurlp/#{local}"}
        end

      _other ->
        {:error, :malformed}
    end
  end

  def well_known_url(_other), do: {:error, :malformed}

  @doc """
  Resolves the LNURL-pay well-known endpoint and validates the
  returned metadata, WITHOUT fetching a bolt11. Used at
  destination-set time to reject malformed / hostile / private-IP
  destinations before they can be stored on the account.
  """
  @spec probe(ln_address(), atom()) :: {:ok, map()} | {:error, term()}
  def probe(ln_address, finch_name) do
    with {:ok, url} <- well_known_url(ln_address),
         {:ok, metadata} <- http_get_json(url, finch_name, @max_redirects) do
      validate_metadata(metadata)
    end
  end

  @doc """
  Resolves the address, validates metadata, and fetches a fresh
  bolt11 for `amount_sats`. Comment (LUD-12) is passed through the
  callback query when metadata advertises support.
  """
  @spec fetch_invoice(ln_address(), pos_integer(), atom(), keyword()) ::
          {:ok, resolved()} | {:error, term()}
  def fetch_invoice(ln_address, amount_sats, finch_name, opts \\ [])
      when is_integer(amount_sats) and amount_sats > 0 do
    comment = Keyword.get(opts, :comment)

    with {:ok, url} <- well_known_url(ln_address),
         {:ok, metadata} <- http_get_json(url, finch_name, @max_redirects),
         {:ok, valid} <- validate_metadata(metadata),
         :ok <- validate_amount(amount_sats, valid),
         callback = build_callback_url(valid.callback, amount_sats, comment, valid),
         {:ok, invoice_response} <- http_get_json(callback, finch_name, @max_redirects),
         {:ok, bolt11} <- extract_bolt11(invoice_response),
         {:ok, payment_hash} <- Bolt11.payment_hash(bolt11),
         :ok <- verify_invoice_amount(bolt11, amount_sats) do
      {:ok, %{bolt11: bolt11, payment_hash: payment_hash, callback_url: callback}}
    end
  end

  # --- Metadata validation ---

  defp validate_metadata(%{"tag" => "payRequest"} = md) do
    with {:ok, callback} <- extract_string(md, "callback"),
         {:ok, min_msat} <- extract_positive_int(md, "minSendable"),
         {:ok, max_msat} <- extract_positive_int(md, "maxSendable"),
         :ok <- check_range(min_msat, max_msat),
         {:ok, comment_allowed} <- extract_comment_allowed(md) do
      {:ok,
       %{
         callback: callback,
         min_msat: min_msat,
         max_msat: max_msat,
         comment_allowed: comment_allowed
       }}
    end
  end

  defp validate_metadata(_other), do: {:error, :invalid_metadata_tag}

  defp extract_string(md, key) do
    case Map.get(md, key) do
      s when is_binary(s) and byte_size(s) > 0 -> {:ok, s}
      _other -> {:error, {:missing_field, key}}
    end
  end

  defp extract_positive_int(md, key) do
    case Map.get(md, key) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _other -> {:error, {:missing_field, key}}
    end
  end

  defp check_range(min_msat, max_msat) when min_msat <= max_msat, do: :ok
  defp check_range(_min, _max), do: {:error, :invalid_msat_range}

  defp extract_comment_allowed(md) do
    case Map.get(md, "commentAllowed", 0) do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      _other -> {:ok, 0}
    end
  end

  defp validate_amount(sats, %{min_msat: min_msat, max_msat: max_msat}) do
    msat = sats * 1_000

    cond do
      msat < min_msat -> {:error, {:amount_out_of_range, :below_min}}
      msat > max_msat -> {:error, {:amount_out_of_range, :above_max}}
      true -> :ok
    end
  end

  defp build_callback_url(callback, sats, comment, valid) do
    uri = URI.parse(callback)
    existing = URI.decode_query(uri.query || "")

    base = Map.put(existing, "amount", Integer.to_string(sats * 1_000))

    query =
      case truncated_comment(comment, valid.comment_allowed) do
        nil -> base
        c -> Map.put(base, "comment", c)
      end

    URI.to_string(%{uri | query: URI.encode_query(query)})
  end

  defp truncated_comment(nil, _max_len), do: nil
  defp truncated_comment(_c, 0), do: nil

  defp truncated_comment(c, max_len) when is_binary(c) and is_integer(max_len) do
    if byte_size(c) <= max_len, do: c, else: binary_part(c, 0, max_len)
  end

  defp truncated_comment(_c, _max_len), do: nil

  defp extract_bolt11(%{"pr" => pr}) when is_binary(pr) and byte_size(pr) > 0, do: {:ok, pr}
  defp extract_bolt11(_other), do: {:error, :missing_invoice_pr}

  defp verify_invoice_amount(bolt11, expected_sats) do
    case Bolt11.parse_amount(bolt11) do
      {:ok, ^expected_sats} ->
        :ok

      {:ok, actual} ->
        {:error, {:invoice_amount_mismatch, expected: expected_sats, got: actual}}

      {:error, _reason} = err ->
        err
    end
  end

  # --- HTTP with SSRF hardening ---

  defp http_get_json(_url, _finch_name, redirects_left) when redirects_left < 0 do
    {:error, :redirect_limit_exceeded}
  end

  defp http_get_json(url, finch_name, redirects_left) do
    with {:ok, %URI{scheme: "https", host: host, port: port} = uri} when is_binary(host) <-
           {:ok, URI.parse(url)},
         :ok <- ensure_public_host(host),
         {:ok, response} <- do_get(uri, port, finch_name) do
      handle_response(response, url, finch_name, redirects_left)
    else
      {:ok, %URI{}} -> {:error, :non_https_url}
      other -> other
    end
  end

  defp do_get(%URI{} = uri, _port, finch_name) do
    req = Finch.build(:get, URI.to_string(uri), [{"accept", "application/json"}])

    Finch.request(req, finch_name,
      receive_timeout: @total_timeout_ms,
      pool_timeout: @connect_timeout_ms
    )
  end

  defp handle_response(
         %Finch.Response{status: status, headers: headers},
         _url,
         finch_name,
         redirects_left
       )
       when status in 301..308 do
    case fetch_header(headers, "location") do
      nil ->
        {:error, :redirect_without_location}

      location ->
        http_get_json(location, finch_name, redirects_left - 1)
    end
  end

  defp handle_response(%Finch.Response{status: status, body: body}, _url, _finch_name, _redirects)
       when status in 200..299 do
    if byte_size(body) > @max_response_bytes do
      {:error, :response_too_large}
    else
      case Jason.decode(body) do
        {:ok, %{} = map} -> {:ok, map}
        {:ok, _non_map} -> {:error, :non_object_response}
        {:error, _reason} = err -> err
      end
    end
  end

  defp handle_response(%Finch.Response{status: status, body: body}, _url, _finch_name, _redirects) do
    {:error, {:http_error, status, safe_body_slice(body)}}
  end

  defp fetch_header(headers, key) do
    key_lc = String.downcase(key)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == key_lc, do: v
    end)
  end

  defp safe_body_slice(body) when is_binary(body) do
    if byte_size(body) > 256, do: binary_part(body, 0, 256), else: body
  end

  # --- SSRF: DNS resolve + private-range blocklist ---

  defp ensure_public_host(host) when is_binary(host) do
    case resolve_ips(host) do
      {:ok, []} ->
        {:error, :dns_no_records}

      {:ok, ips} ->
        if Enum.all?(ips, &public_ip?/1),
          do: :ok,
          else: {:error, :private_ip_blocked}

      {:error, reason} ->
        {:error, {:dns_error, reason}}
    end
  end

  defp resolve_ips(host) do
    charlist = String.to_charlist(host)
    v4 = safe_getaddrs(charlist, :inet)
    v6 = safe_getaddrs(charlist, :inet6)

    case {v4, v6} do
      {{:ok, a}, {:ok, b}} -> {:ok, a ++ b}
      {{:ok, a}, _v6_err} -> {:ok, a}
      {_v4_err, {:ok, b}} -> {:ok, b}
      {{:error, reason}, _v6_err} -> {:error, reason}
    end
  end

  defp safe_getaddrs(host, family) do
    :inet.getaddrs(host, family, @connect_timeout_ms)
  rescue
    _exception -> {:error, :dns_exception}
  end

  # Public so tests exercise the security boundary directly. RFC1918
  # + loopback + link-local + carrier-grade NAT + reserved ranges are
  # blocked; anything else is treated as routable public IP.
  @doc false
  @spec public_ip?(:inet.ip_address()) :: boolean()
  def public_ip?({10, _b1, _b2, _b3}), do: false
  def public_ip?({127, _b1, _b2, _b3}), do: false
  def public_ip?({169, 254, _b2, _b3}), do: false
  def public_ip?({172, b, _b2, _b3}) when b >= 16 and b <= 31, do: false
  def public_ip?({192, 168, _b2, _b3}), do: false
  # 100.64.0.0/10 — carrier-grade NAT
  def public_ip?({100, b, _b2, _b3}) when b >= 64 and b <= 127, do: false
  # 0.0.0.0/8 — "this network"
  def public_ip?({0, _b1, _b2, _b3}), do: false
  # 224.0.0.0/4 — multicast, 240.0.0.0/4 — reserved
  def public_ip?({a, _b1, _b2, _b3}) when a >= 224, do: false
  def public_ip?({_a, _b, _c, _d}), do: true

  # IPv6 ::1 (loopback)
  def public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  # IPv6 fc00::/7 — ULA
  def public_ip?({a, _b, _c, _d, _e, _f, _g, _h}) when a >= 0xFC00 and a <= 0xFDFF, do: false
  # IPv6 fe80::/10 — link-local
  def public_ip?({a, _b, _c, _d, _e, _f, _g, _h}) when a >= 0xFE80 and a <= 0xFEBF, do: false
  # IPv6 ::ffff:x.x.x.x — IPv4-mapped, delegate to v4 check
  def public_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    public_ip?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})
  end

  def public_ip?({_a, _b, _c, _d, _e, _f, _g, _h}), do: true

  def public_ip?(_other), do: false

  # --- LN Address parsing helpers ---

  defp valid_local?(local) do
    byte_size(local) <= 64 and
      Regex.match?(~r/\A[A-Za-z0-9._+\-]+\z/, local)
  end

  defp valid_domain?(domain) do
    byte_size(domain) <= 253 and
      Regex.match?(
        ~r/\A[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)+\z/,
        domain
      )
  end
end
