class SessionsController < ApplicationController
  skip_before_action :require_authentication, only: [:new, :create]

  def new
  end

  def create
    user = User.authenticate(params[:access_key])

    if user
      session[:user_id] = user.id
      redirect_to root_path, notice: I18n.t('login.welcome', name: user.name)
    else
      flash.now[:alert] = I18n.t('login.invalid_key')
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    session.delete(:user_id)
    redirect_to login_path, notice: I18n.t('login.logged_out')
  end
end
