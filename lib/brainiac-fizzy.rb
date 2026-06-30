# frozen_string_literal: true

# Brainiac Fizzy Plugin
#
# Fizzy card management integration for Brainiac.
# Handles card assignment, comments, @mentions, duplicate detection, and deploy shortcuts.
#
# This plugin extracts the Fizzy handler from brainiac core into a standalone gem,
# proving the plugin architecture works for real, production-grade handlers.

require_relative "brainiac/plugins/fizzy"
