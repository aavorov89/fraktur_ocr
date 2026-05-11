class DiagnosticsController < ApplicationController
  def boom
    render json: { status: "ok" }, status: :ok
  end
end
