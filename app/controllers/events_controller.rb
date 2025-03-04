class EventsController < ApplicationController
  include SquashManyDuplicatesMixin # Provides squash_many_duplicates

  # GET /events
  # GET /events.xml
  def index
    order = params[:order] || 'date'
    order = \
      case order
        when 'date'
          'start_time'
        when 'name'
          'lower(events.title), start_time'
        when 'venue'
          'lower(venues.title), start_time'
        end

    @start_date = date_or_default_for(:start)
    @end_date = date_or_default_for(:end)
    @events_deferred = lambda {
      params[:date] ?
        Event.find_by_dates(@start_date, @end_date, :order => order) :
        Event.find_future_events(:order => order)
    }
    @perform_caching = params[:order].blank? && params[:date].blank?

    @page_title = "Events"

    render_events(@events_deferred)
  end

  # GET /events/1
  # GET /events/1.xml
  def show
    begin
      @event = Event.find(params[:id])
    rescue ActiveRecord::RecordNotFound => e
      flash[:failure] = e.to_s
      return redirect_to(:action => :index)
    end

    if @event.duplicate?
      return redirect_to(event_path(@event.duplicate_of))
    end

    @page_title = @event.title
    @hcal = render_to_string :partial => 'list_item.html.erb',
        :locals => { :event => @event, :show_year => true }

    # following used by Show so that weekday is rendered
    @show_hcal = render_to_string :partial => 'hcal.html.erb',
        :locals => { :event => @event, :show_year => true }

    respond_to do |format|
      format.html # show.html.erb
      format.xml  { render :xml  => @event.to_xml(:include => :venue) }
      format.json { render :json => @event.to_json(:include => :venue), :callback => params[:callback] }
      format.ics { ical_export([@event]) }
    end
  end

  # GET /events/new
  # GET /events/new.xml
  def new
    @event = Event.new(params[:event])
    @page_title = "Add an Event"

    respond_to do |format|
      format.html # new.html.erb
      format.xml  { render :xml => @event }
    end
  end

  # GET /events/1/edit
  def edit
    @event = Event.find(params[:id])
    @page_title = "Editing '#{@event.title}'"
  end

  # POST /events
  # POST /events.xml
  def create
    @event = Event.new(params[:event])
    @event.associate_with_venue(venue_ref(params))
    has_new_venue = @event.venue && @event.venue.new_record?

    Time.zone = params[:start_time_zone]
    @event.start_time = params[:start_date], Time.zone.parse(params[:start_time])
    Time.zone = params[:end_time_zone]
    @event.end_time = params[:end_date], Time.zone.parse(params[:end_time])

    if evil_robot = params[:trap_field].present?
      flash[:failure] = "<h3>Evil Robot</h3> We didn't create this event because we think you're an evil robot. If you're really not an evil robot, look at the form instructions more carefully. If this doesn't work please file a bug report and let us know."
    end

    respond_to do |format|
      if !evil_robot && params[:preview].nil? && @event.save
        flash[:success] = 'Your event was successfully created. '
        format.html {
          if has_new_venue && !params[:venue_name].blank?
            flash[:success] += " Please tell us more about where it's being held."
            redirect_to(edit_venue_url(@event.venue, :from_event => @event.id))
          else
            redirect_to(@event)
          end
        }
        format.xml  { render :xml => @event, :status => :created, :location => @event }
      else
        @event.valid? if params[:preview]
        format.html { render :action => "new" }
        format.xml  { render :xml => @event.errors, :status => :unprocessable_entity }
      end
    end
  end

  # PUT /events/1
  # PUT /events/1.xml
  def update
    @event = Event.find(params[:id])
    @event.associate_with_venue(venue_ref(params))
    has_new_venue = @event.venue && @event.venue.new_record?

    Time.zone = params[:start_time_zone]
    @event.start_time = params[:start_date], Time.zone.parse(params[:start_time])
    Time.zone = params[:end_time_zone]
    @event.end_time = params[:end_date], Time.zone.parse(params[:end_time])


    if evil_robot = !params[:trap_field].blank?
      flash[:failure] = "<h3>Evil Robot</h3> We didn't update this event because we think you're an evil robot. If you're really not an evil robot, look at the form instructions more carefully. If this doesn't work please file a bug report and let us know."
    end

    respond_to do |format|
      if !evil_robot && params[:preview].nil? && @event.update_attributes(params[:event])
        flash[:success] = 'Event was successfully updated.'
        format.html {
          if has_new_venue && !params[:venue_name].blank?
            flash[:success] += "Please tell us more about where it's being held."
            redirect_to(edit_venue_url(@event.venue, :from_event => @event.id))
          else
            redirect_to(@event)
          end
        }
        format.xml  { head :ok }
      else
        if params[:preview]
          @event.attributes = params[:event]
          @event.valid?
          @event.tags.reload # Reload the #tags association because its members may have been modified when #tag_list was set above.
        end
        format.html { render :action => "edit" }
        format.xml  { render :xml => @event.errors, :status => :unprocessable_entity }
      end
    end
  end

  # DELETE /events/1
  # DELETE /events/1.xml
  def destroy
    @event = Event.find(params[:id])
    @event.destroy

    respond_to do |format|
      format.html { redirect_to(events_url) }
      format.xml  { head :ok }
    end
  end

  # GET /events/duplicates
  def duplicates
    @type = params[:type]
    begin
      @grouped_events = Event.find_duplicates_by_type(@type)
    rescue ArgumentError => e
      @grouped_events = {}
      flash[:failure] = "#{e}"
    end

    @page_title = "Duplicate Event Squasher"

    respond_to do |format|
      format.html # index.html.erb
      format.xml  { render :xml => @grouped_events }
    end
  end

  # Search!!!
  def search
    # TODO Refactor this method and move much of it to the record-managing
    # logic into a generalized Event::search method.

    @query = params[:query].presence
    @tag = params[:tag].presence
    @current = ["1", "true"].include?(params[:current])
    @order = params[:order].presence

    if @order && @order == "score" && @tag
      flash[:failure] = "You cannot sort tags by score"
      @order = nil
    end

    if !@query && !@tag
      flash[:failure] = "You must enter a search query"
      return redirect_to(root_path)
    end

    if @query && @tag
      # TODO make it possible to search by tag and query simultaneously
      flash[:failure] = "You can't search by tag and query at the same time"
      return redirect_to(root_path)
    elsif @query
      @grouped_events = Event.search_keywords_grouped_by_currentness(@query, :order => @order, :skip_old => @current)
    elsif @tag
      @grouped_events = Event.search_tag_grouped_by_currentness(@tag, :order => @order, :current => @current)
    end

    # setting @events so that we can reuse the index atom builder
    @events = @grouped_events[:past] + @grouped_events[:current]

    @page_title = @tag ? "Events tagged with '#{@tag}'" : "Search Results for '#{@query}'"

    render_events(@events)
  end

  # Display a new event form pre-filled with the contents of an existing record.
  def clone
    @event = Event.find(params[:id]).to_clone
    @page_title = "Clone an existing Event"

    respond_to do |format|
      format.html {
        flash[:success] = "This is a new event cloned from an existing one. Please update the fields, like the time and description."
        render "new.html.erb"
      }
      format.xml  { render :xml => @event }
    end
  end

protected

  # Export +events+ to an iCalendar file.
  def ical_export(events=nil)
    events = events || Event.find_future_events
    render(:text => Event.to_ical(events, :url_helper => lambda{|event| event_url(event)}), :mime_type => 'text/calendar')
  end

  # Render +events+ for a particular format.
  def render_events(events)
    respond_to do |format|
      format.html # *.html.erb
      format.kml  # *.kml.erb
      format.ics  { ical_export(yield_events(events)) }
      format.atom { render :template => 'events/index' }
      format.xml  { render :xml  => yield_events(events).to_xml(:include => :venue) }
      format.json { render :json => yield_events(events).to_json(:include => :venue), :callback => params[:callback] }
    end
  end

  # Return an array of Events from a +container+, which can either be an array
  # of Events or a lambda that returns an array of Events.
  def yield_events(container)
    return container.respond_to?(:call) ? container.call : container
  end

  # Venues may be referred to in the params hash either by id or by name. This
  # method looks for whichever type of reference is present and returns that
  # reference. If both a venue id and a venue name are present, then the venue
  # id is returned.
  #
  # If a venue id is returned it is cast to an integer for compatibility with
  # Event#associate_with_venue.
  def venue_ref(p)
    if (p[:event] && !p[:event][:venue_id].blank?)
      p[:event][:venue_id].to_i
    else
      p[:venue_name]
    end
  end

  # Return the default start date.
  def default_start_date
    Time.today
  end

  # Return the default end date.
  def default_end_date
    Time.today + 3.months
  end

  # Return a date parsed from user arguments or a default date. The +kind+
  # is a value like :start, which refers to the `params[:date][+kind+]` value.
  # If there's an error, set an error message to flash.
  def date_or_default_for(kind)
    if params[:date].present?
      if params[:date].respond_to?(:has_key?)
        if params[:date].has_key?(kind)
          if params[:date][kind].present?
            begin
              return Date.parse(params[:date][kind])
            rescue ArgumentError => e
              append_flash :failure, "Can't filter by an invalid #{kind} date."
            end
          else
            append_flash :failure, "Can't filter by an empty #{kind} date."
          end
        else
          append_flash :failure, "Can't filter by a missing #{kind} date."
        end
      else
        append_flash :failure, "Can't filter by a malformed #{kind} date."
      end
    end
    return self.send("default_#{kind}_date")
  end
end
