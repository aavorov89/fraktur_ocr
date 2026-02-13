class DocumentsController < ApplicationController
  def new
    @document = Document.new
  end

  def create
    @document = Document.new(document_params)

    if @document.save
      redirect_to @document, notice: "Document uploaded successfully"
    else
      flash.now[:alert] = "Failed to upload document: #{@document.errors.full_messages.join(', ')}"
      render :new, status: :unprocessable_entity
    end
  rescue StandardError => e
    Rails.logger.error "Document upload error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    flash.now[:alert] = "Upload failed: #{e.message}"
    @document ||= Document.new
    render :new, status: :unprocessable_entity
  end

  def show
    @document = Document.find(params[:id])
    @ocr_request = @document.ocr_requests.order(created_at: :desc).first
  end

  private

  def document_params
    params.require(:document).permit(:name, :file)
  end
end
