defmodule FireBird.LnurlTest do
  use ExUnit.Case, async: true

  alias FireBird.Lnurl

  describe "well_known_url/1" do
    test "builds the lnurlp URL for a valid address" do
      assert {:ok, "https://example.com/.well-known/lnurlp/alice"} =
               Lnurl.well_known_url("alice@example.com")
    end

    test "accepts subdomains and multi-dot TLDs" do
      assert {:ok, "https://mail.example.co.uk/.well-known/lnurlp/bob"} =
               Lnurl.well_known_url("bob@mail.example.co.uk")
    end

    test "accepts common special chars in localpart" do
      assert {:ok, _url} = Lnurl.well_known_url("a.b+c-d_e@example.com")
    end

    test "rejects missing @" do
      assert {:error, :malformed} = Lnurl.well_known_url("noatsign")
    end

    test "rejects empty local part" do
      assert {:error, :malformed} = Lnurl.well_known_url("@example.com")
    end

    test "rejects empty domain" do
      assert {:error, :malformed} = Lnurl.well_known_url("alice@")
    end

    test "rejects domain without a TLD" do
      assert {:error, :malformed_domain} = Lnurl.well_known_url("alice@localhost")
    end

    test "rejects invalid characters in local part" do
      assert {:error, :malformed_local} = Lnurl.well_known_url("alice bob@example.com")
    end

    test "rejects >64 byte local part" do
      long = String.duplicate("a", 65)
      assert {:error, :malformed_local} = Lnurl.well_known_url(long <> "@example.com")
    end

    test "rejects non-binary input" do
      assert {:error, :malformed} = Lnurl.well_known_url(nil)
      assert {:error, :malformed} = Lnurl.well_known_url(:atom)
      assert {:error, :malformed} = Lnurl.well_known_url(123)
    end
  end

  describe "public_ip?/1 SSRF blocklist" do
    test "blocks IPv4 loopback" do
      refute Lnurl.public_ip?({127, 0, 0, 1})
      refute Lnurl.public_ip?({127, 255, 255, 254})
    end

    test "blocks RFC1918 ranges" do
      refute Lnurl.public_ip?({10, 0, 0, 1})
      refute Lnurl.public_ip?({10, 255, 255, 254})
      refute Lnurl.public_ip?({172, 16, 0, 1})
      refute Lnurl.public_ip?({172, 31, 255, 254})
      refute Lnurl.public_ip?({192, 168, 0, 1})
    end

    test "does NOT block 172.15.x.x / 172.32.x.x (adjacent to RFC1918)" do
      assert Lnurl.public_ip?({172, 15, 0, 1})
      assert Lnurl.public_ip?({172, 32, 0, 1})
    end

    test "blocks link-local" do
      refute Lnurl.public_ip?({169, 254, 169, 254})
    end

    test "blocks carrier-grade NAT (100.64.0.0/10)" do
      refute Lnurl.public_ip?({100, 64, 0, 1})
      refute Lnurl.public_ip?({100, 127, 255, 254})
    end

    test "does NOT block 100.63.x.x / 100.128.x.x (adjacent to CGNAT)" do
      assert Lnurl.public_ip?({100, 63, 255, 254})
      assert Lnurl.public_ip?({100, 128, 0, 1})
    end

    test "blocks 0.0.0.0/8" do
      refute Lnurl.public_ip?({0, 0, 0, 0})
      refute Lnurl.public_ip?({0, 255, 255, 254})
    end

    test "blocks multicast and reserved (224.0.0.0/4, 240.0.0.0/4)" do
      refute Lnurl.public_ip?({224, 0, 0, 1})
      refute Lnurl.public_ip?({239, 255, 255, 254})
      refute Lnurl.public_ip?({240, 0, 0, 1})
    end

    test "allows normal public IPv4" do
      assert Lnurl.public_ip?({1, 1, 1, 1})
      assert Lnurl.public_ip?({8, 8, 8, 8})
      assert Lnurl.public_ip?({140, 82, 114, 4})
    end

    test "blocks IPv6 loopback and ULA" do
      refute Lnurl.public_ip?({0, 0, 0, 0, 0, 0, 0, 1})
      refute Lnurl.public_ip?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      refute Lnurl.public_ip?({0xFDFF, 0, 0, 0, 0, 0, 0, 1})
    end

    test "blocks IPv6 link-local (fe80::/10)" do
      refute Lnurl.public_ip?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      refute Lnurl.public_ip?({0xFEBF, 0, 0, 0, 0, 0, 0, 1})
    end

    test "resolves IPv4-mapped IPv6 to the underlying v4 rule" do
      # ::ffff:127.0.0.1 → blocked
      refute Lnurl.public_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
      # ::ffff:8.8.8.8 → allowed
      assert Lnurl.public_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
    end

    test "allows normal IPv6" do
      assert Lnurl.public_ip?({0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888})
    end

    test "rejects garbage input" do
      refute Lnurl.public_ip?(:not_a_tuple)
      refute Lnurl.public_ip?({1, 2, 3})
      refute Lnurl.public_ip?(nil)
    end
  end
end
