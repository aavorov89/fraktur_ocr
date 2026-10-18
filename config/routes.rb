Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Authentication routes
  get "login", to: "sessions#new"
  post "login", to: "sessions#create"
  delete "logout", to: "sessions#destroy"

  # Defines the root path route ("/")
  root "documents#new"

  resources :documents, only: [:new, :create, :show] do
    member do
      put :pdf, action: :upload_pdf, as: :upload_pdf
      match :pdf, action: :pdf_status, via: :head, as: :pdf_status
    end
    scope module: :documents do
      resources :ocr_requests, only: [:create]
      resource :buffer, only: [:destroy]
      resource :correction, only: [:create]
      resource :translation, only: [:create]
      get "pages/:page_number/text_regions", to: "text_regions#show", as: :page_text_regions
      post "pages/:page_number/text_regions", to: "text_regions#create"
      patch "pages/:page_number/text_regions/:index", to: "text_regions#update", as: :page_text_region
      delete "pages/:page_number/text_regions/:index", to: "text_regions#destroy"
    end
  end

  namespace :internal do
    resources :ocr_requests, only: [] do
      member do
        post :render_done
      end
    end
    resources :page_layouts, only: [] do
      member do
        post :render_done
      end
    end
  end

  post "diagnostics/boom", to: "diagnostics#boom", as: :diagnostics_boom
end
