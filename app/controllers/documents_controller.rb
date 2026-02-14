class DocumentsController < ApplicationController
  def new
    @document = Document.new
  end

  def create
    @document = Document.new(document_params)

    if @document.save
      redirect_to @document, notice: t('documents.create.success')
    else
      flash.now[:alert] = t('documents.create.failed', errors: @document.errors.full_messages.join(', '))
      render :new, status: :unprocessable_entity
    end
  rescue StandardError => e
    Rails.logger.error "Document upload error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    flash.now[:alert] = t('documents.create.upload_error', message: e.message)
    @document ||= Document.new
    render :new, status: :unprocessable_entity
  end

  def show
    @document = Document.find(params[:id])
    @ocr_request = @document.ocr_requests.order(created_at: :desc).first
  end

  private

  def document_params
    params.require(:document).permit(:name)
  end
end
