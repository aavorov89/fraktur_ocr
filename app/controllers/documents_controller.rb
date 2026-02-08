class DocumentsController < ApplicationController
  def new
    @document = Document.new
  end

  def create
    @document = Document.new(document_params)

    if @document.save
      redirect_to @document
    else
      render :new, status: :unprocessable_entity
    end
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
