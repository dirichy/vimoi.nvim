#!/bin/sh
exec chezmoi \
  --config "$VIMOI_TEST_CONFIG" \
  --source "$VIMOI_TEST_SOURCE" \
  --destination "$VIMOI_TEST_DESTINATION" \
  "$@"
