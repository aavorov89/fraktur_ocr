class SessionsController < ApplicationController
  skip_before_action :require_authentication, only: [:new, :create]

  def new
  end

  def create
    user = User.authenticate(params[:access_key])

    if user
      session[:user_id] = user.id
      redirect_to root_path, notice: "Welcome, #{user.name}!"
    else
      flash.now[:alert] = "Invalid access key"
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    session.delete(:user_id)
    redirect_to login_path, notice: "You have been logged out"
  end
end
