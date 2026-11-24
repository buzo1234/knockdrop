#!/bin/sh
# Prints the Homebrew formula for a release:  packaging/homebrew-formula.sh VERSION SHA256
set -e
V="$1"; SHA="$2"
[ -n "$V" ] && [ -n "$SHA" ] || { echo "usage: $0 VERSION SHA256" >&2; exit 1; }
cat <<RUBY
class Knockdrop < Formula
  desc "Share files between Macs by knocking the same rhythm"
  homepage "https://github.com/buzo1234/knockdrop"
  url "https://github.com/buzo1234/knockdrop/releases/download/v${V}/knockdrop-${V}.tar.gz"
  sha256 "${SHA}"
  license "MIT"

  depends_on :macos

  def install
    inreplace "knockdrop.py", /^__version__ = .*\$/, "__version__ = \"#{version}\""
    libexec.install "knockdrop", "knockdrop.py", "macimu"
    bin.install_symlink libexec/"knockdrop"
  end

  def caveats
    <<~EOS
      Run \`knockdrop check\` once. If it reports Local Network access as BLOCKED, allow your
      terminal app in System Settings > Privacy & Security > Local Network.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/knockdrop --version")
  end
end
RUBY
