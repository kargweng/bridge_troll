class RsvpsController < ApplicationController
  before_filter :authenticate_user!
  before_filter :assign_event
  before_filter :load_rsvp, except: [:volunteer, :learn, :create]
  before_filter :redirect_if_rsvp_exists, only: [:volunteer, :learn]
  before_filter :redirect_if_event_upcoming

  def volunteer
    last_rsvp = current_user.rsvps.includes(:event).order('events.ends_at').last

    @rsvp = @event.rsvps.build(last_rsvp ? last_rsvp.volunteer_carryover_attributes : {})
    @rsvp.role = Role::VOLUNTEER
    @rsvp.event_session_ids = @event.event_sessions.pluck(:id)
    render :new
  end

  def learn
    @rsvp = @event.rsvps.build
    @rsvp.role = Role::STUDENT
    @rsvp.event_session_ids = @event.event_sessions.pluck(:id)
    render :new
  end

  def create
    @rsvp = Rsvp.new(rsvp_params)
    @rsvp.event = @event
    @rsvp.user = current_user
    if [Role::VOLUNTEER.id, Role::STUDENT.id].include?(params[:rsvp][:role_id].to_i)
      @rsvp.role = Role.find(params[:rsvp][:role_id])
    end

    Rsvp.transaction do
      if @event.at_limit? && @rsvp.role_student?
        @rsvp.waitlist_position = (@event.rsvps.maximum(:waitlist_position) || 0) + 1
      end
      set_dietary_restrictions(@rsvp, params[:dietary_restrictions])

      if @rsvp.save
        if @event.location
          if params[:affiliate_with_chapter]
            @rsvp.user.chapter_ids += [@event.chapter.id]
          else
            @rsvp.user.chapter_ids -= [@event.chapter.id]
          end
        end

        @rsvp.user.update_attributes(gender: params[:user][:gender])
        RsvpMailer.confirmation(@rsvp).deliver
        notice_message = 'Thanks for signing up!'
        notice_message << " We've added you to the waitlist." if @rsvp.waitlisted?
        redirect_to @event, notice: notice_message
      else
        render :new
      end
    end
  end

  def edit
  end

  def update
    set_dietary_restrictions(@rsvp,  params[:dietary_restrictions])
    if @rsvp.update_attributes(rsvp_params)
      @rsvp.user.update_attributes(gender: params[:user][:gender])
      redirect_to @event
    else
      render :edit
    end
  end

  def destroy
    Rsvp.transaction do
      @rsvp.destroy
      @event.reorder_waitlist!
    end
    redirect_to events_path, notice: "You are now no longer signed up for #{@event.title}"
  end

  protected

  def rsvp_params
    role_id = params[:rsvp][:role_id].to_i
    params.require(:rsvp).permit(Rsvp::PERMITTED_ATTRIBUTES + [event_session_ids: []]).tap do |params|
      if role_id == Role::STUDENT.id
        user_choices = Array(params[:event_session_ids]).select(&:present?).map(&:to_i)
        required_sessions = @event.event_sessions.where(required_for_students: true).pluck(:id)
        params[:event_session_ids] = user_choices | required_sessions
      end
      if @event.event_sessions.length == 1
        params[:event_session_ids] = [@event.event_sessions.first.id]
      end
    end
  end

  def set_dietary_restrictions(rsvp, restrictions_params)
    restrictions_params ||= {}

    rsvp.dietary_restrictions = restrictions_params.keys.map do |diet|
      DietaryRestriction.new(restriction: diet)
    end
  end

  def load_rsvp
    @rsvp = Rsvp.find_by_id(params[:id])
    unless @rsvp && @rsvp.user == current_user
      redirect_to events_path, notice: 'You are not signed up for this event'
    end
    false
  end

  def redirect_if_rsvp_exists
    redirect_to @event if @event.rsvps.where(user_id: current_user.id).present?
  end

  def redirect_if_event_upcoming
    redirect_to events_path if @event.past?
  end

  def assign_event
    @event = Event.find_by_id(params[:event_id])
  end
end
