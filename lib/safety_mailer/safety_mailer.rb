module SafetyMailer
  class Carrier
    attr_accessor :matchers, :settings, :mail

    def initialize(params = {})
      self.matchers = params[:allowed_matchers] || []
      self.settings = params[:delivery_method_settings] || {}
      delivery_method = params[:delivery_method] || :smtp
      @delivery_method = ActionMailer::Base.delivery_methods[delivery_method].new(settings)
      @sendgrid_options = {}
    end

    def deliver!(mail)
      self.mail = mail

      if sendgrid?
        deliver_sendgrid!(mail)
      else
        deliver_standard!(mail)
      end
    end

    private

    def deliver_standard!(mail)
      mail.to = filter(mail.to)
      mail.cc = filter(mail.cc)
      mail.bcc = filter(mail.bcc)
      allowed = [*mail.to, *mail.cc, *mail.bcc].compact

      deliver_filtered!(mail, allowed)
    end

    def deliver_sendgrid!(mail)
      allowed = filter(@sendgrid_options['to'])
      mail['X-SMTPAPI'].value = prepare_sendgrid_delivery(allowed) if sendgrid?
      mail.to = allowed

      deliver_filtered!(mail, allowed)
    end

    def deliver_filtered!(mail, allowed)
      if allowed.empty?
        log "*** safety_mailer - no allowed recipients ... suppressing delivery altogether"
        return
      end

      @delivery_method.deliver!(nil)      
    end

    def sendgrid?
      @sendgrid ||= !!if mail['X-SMTPAPI']
        @sendgrid_options = JSON.parse(mail['X-SMTPAPI'].value)
      end
    rescue JSON::ParserError
      log "*** safety_mailer was unable to parse the X-SMTPAPI header"
    end

    def filter(addresses)
      addresses ||= []
      allowed, rejected = addresses.partition { |r| whitelisted?(r) }

      rejected.each { |addr| log "*** safety_mailer delivery suppressed for #{addr}" }
      allowed.each { |addr| log "*** safety_mailer delivery allowed for #{addr}" }

      allowed
    end

    def whitelisted?(recipient)
      matchers.any? { |m| recipient =~ m }
    end

    # Handles clean-up for additional SendGrid features that may be required
    # by changes to the recipient list. Expects the passed-in Array of
    # addresses to have been whitelist-filtered already.
    def prepare_sendgrid_delivery(addresses)
      amendments = { 'to' => addresses }

      # The SendGrid Substitution Tags feature, if used, requires that an
      # ordered Array of substitution values aligns with the Array of
      # recipients in the "to" field of the API header. If substitution key is
      # present, this filters the Arrays for each template to re-align with our
      # whitelisted addresses.
      #
      # @see http://docs.sendgrid.com/documentation/api/smtp-api/developers-guide/substitution-tags/
      if substitutions = @sendgrid_options['sub']
        substitutions.each do |template, values|
          values = @sendgrid_options['to'].zip(values).map do |addr, value|
            value if addresses.include?(addr)
          end

          substitutions[template] = values.compact
        end

        amendments['sub'] = substitutions
      end

      JSON.generate(@sendgrid_options.merge(amendments))
    end

    def log(msg)
      Rails.logger.warn(msg) if defined?(Rails)
    end

  end
end
