class DocumentsController < ApplicationController
  MAX_PDF_BYTES = 200.megabytes
  ALLOWED_PDF_TYPES = %w[application/pdf application/x-pdf].freeze

  # CSRF for PUT /documents/:id/pdf is handled in JS via the meta tag header,
  # but a raw binary body cannot also include the form-style CSRF token. We
  # require X-CSRF-Token header instead — Rails verifies it automatically.

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
  end

  def upload_pdf
    @document = Document.find(params[:id])
    bytes = read_pdf_body
    return head(:unsupported_media_type) if bytes.nil?
    return head(:payload_too_large) if bytes.bytesize > MAX_PDF_BYTES
    return head(:unprocessable_entity) unless bytes.start_with?("%PDF-".b)

    FileUtils.mkdir_p(Document.pdf_root)
    final = @document.pdf_path
    tmp = "#{final}.tmp"
    File.binwrite(tmp, bytes)
    File.rename(tmp, final)

    @document.update!(pdf_stored_at: Time.current)
    head :no_content
  end

  def pdf_status
    @document = Document.find(params[:id])
    head(@document.pdf_stored? ? :ok : :not_found)
  end

  private

  def document_params
    params.require(:document).permit(:name)
  end

  # Accept either a raw binary body (Content-Type: application/pdf) or a
  # multipart upload (params[:file]). Returns the bytes or nil if the type
  # isn't acceptable.
  def read_pdf_body
    if request.content_type.to_s.start_with?("multipart/")
      file = params[:file]
      return nil unless file.respond_to?(:read)
      return nil unless ALLOWED_PDF_TYPES.include?(file.content_type)
      file.read
    elsif ALLOWED_PDF_TYPES.include?(request.content_type)
      request.body.read
    end
  end
end
