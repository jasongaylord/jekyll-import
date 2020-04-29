# frozen_string_literal: false

module JekyllImport
  module Importers
    class Test < Importer
      def self.require_deps
        JekyllImport.require_with_fallback(%w(
          rubygems
        ))
      end

      def self.process()
        warn "This is running."
      end

    end
  end
end