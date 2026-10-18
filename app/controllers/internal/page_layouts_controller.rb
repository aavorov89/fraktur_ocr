# The Go renderer finished a render_pdf_page job: the page JPEG is on disk,
# hand it to Mistral for text-region detection.
class Internal::PageLayoutsController < Internal::BaseController
  def render_done
    LayoutDetectionJob.perform_later(params[:id].to_i)
    head :no_content
  end
end
