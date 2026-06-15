#!/usr/bin/env bash
# Install PECL extensions for the current mise PHP version.
# Run this after installing a new PHP version with mise.
#
# Usage: ~/.config/php/install-extensions.sh

set -euo pipefail

EXTENSIONS=(
  igbinary
  imagick
  memcached
  msgpack
  opentelemetry
  pcov
  redis
  swoole
  xdebug
)

echo "Installing PECL extensions for $(php --version | head -1)..."

for ext in "${EXTENSIONS[@]}"; do
  if php -m 2>/dev/null | grep -qi "^${ext}$"; then
    echo "  ✓ ${ext} (already loaded)"
  else
    echo "  → Installing ${ext}..."
    pecl install "$ext" < /dev/null || echo "  ✗ ${ext} failed — may need manual install"
  fi
done

echo "Done. Verify with: php -m"
