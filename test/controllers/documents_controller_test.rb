require "test_helper"

class DocumentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(name: "Tester", access_key: "test-#{SecureRandom.hex(4)}")
    post login_path, params: { access_key: @user.access_key }

    @document = Document.create!(name: "Doc")
    @tmp_root = Dir.mktmpdir
    ENV["PDF_ROOT_DIR"] = @tmp_root
  end

  teardown do
    FileUtils.rm_rf(@tmp_root) if @tmp_root
    ENV.delete("PDF_ROOT_DIR")
  end

  test "pdf_status returns 404 when the file is not on disk" do
    head pdf_status_document_path(@document)
    assert_response :not_found
  end

  test "upload_pdf writes the body to <PDF_ROOT_DIR>/<id>.pdf" do
    pdf_bytes = "%PDF-1.4\n%fake\n".b
    put upload_pdf_document_path(@document),
        params: pdf_bytes,
        headers: { "Content-Type" => "application/pdf" }

    assert_response :no_content
    assert File.exist?(@document.pdf_path)
    assert_equal pdf_bytes, File.binread(@document.pdf_path)
    assert @document.reload.pdf_stored_at.present?
  end

  test "upload_pdf rejects non-PDF content" do
    put upload_pdf_document_path(@document),
        params: "<html>not a pdf</html>".b,
        headers: { "Content-Type" => "application/pdf" }

    assert_response :unprocessable_entity
  end

  test "pdf_status returns 200 once the file exists" do
    FileUtils.mkdir_p(@tmp_root)
    File.binwrite(@document.pdf_path, "%PDF-1.4\n".b)
    @document.update!(pdf_stored_at: Time.current)

    head pdf_status_document_path(@document)
    assert_response :ok
  end
end
