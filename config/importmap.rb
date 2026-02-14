# Pin npm packages by running ./bin/importmap

pin "application"
pin "pdfjs-dist" # @5.0.375
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@rails/activestorage", to: "@rails--activestorage.js" # @8.1.200
