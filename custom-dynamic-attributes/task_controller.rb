class TasksController < ApplicationController
  def new
    @task = Task.new
  end

  def create
    @task = Task.new(task_params)
    custom_fields = params[:custom_fields] || {}

    custom_fields.each do |key, value|
      Task.add_dynamic_attribute(key)
      @task.send("#{key}=", value)
    end

    if @task.save
      redirect_to @task, notice: 'Task was successfully created.'
    else
      render :new
    end
  end

  private

  def task_params
    params.require(:task).permit(:name)
  end
end
