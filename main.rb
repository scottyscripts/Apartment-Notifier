require 'nokogiri'
require 'open-uri'
require 'json'
require 'sendgrid-ruby'
require 'erb'
require 'aws-sdk-s3'

def lambda_handler(event:, context:)
  ApartmentNotifier.run()
end

class ApartmentNotifier
  include SendGrid

  def self.run()
    # location of HTML with apartment listings
    url = 'URL with apartment listings'
    # parse HTML using Nokogiri
    doc = Nokogiri::HTML(open(url))
    
    # get all nodes matching css selector
    apartment_containers_html = doc.css('li.apartment-card')
    
    # create list of apartment info
    apartments_info = apartment_containers_html.map do |apartment_container_html|
      info = apartment_container_html.css('div.content')
    
      title = info.css('div.title').text
      unit_number = title.split(' ').last
      details = info.css('div.details').text
      price = info.css('div.price').text
      availability = info.css('div.availability').text
    
      { 
        unit_number: unit_number,
        price: price,
        availability: availability
      }
    end
    
    s3 = Aws::S3::Client.new(region: 'us-east-1')
    
    res = s3.get_object({
      bucket: 'apartment-scraper',
      key: 'apartments.json'
    })
    
    old_apartments_info = JSON.parse(
      res.body.read,
      {symbolize_names: true}
    )
    
    # compare new and old apartment data
    new_apartments = []
    price_changes = []
    availability_changes = []
    no_changes = []
    removed_apartments = []

    apartments_info.each do |apartment_info|
      unit_number = apartment_info[:unit_number]
      price = apartment_info[:price]
      availability = apartment_info[:availability]

      done = false

      old_apartments_info.each_with_index do |old_apartment_info, i|
        break if done
        
        has_same_unit_number = old_apartment_info.has_value?(unit_number)
        has_same_price = old_apartment_info.has_value?(price)
        has_same_availability = old_apartment_info.has_value?(availability)

        is_last = i == (old_apartments_info.size - 1)

        case
          # nothing changed
          when has_same_unit_number && has_same_price && has_same_availability
            no_changes << apartment_info
            done = true
          # price changed
          when has_same_unit_number && has_same_availability
            price_changes << apartment_info
            done = true
          # availability changed
          when has_same_unit_number && has_same_price
            availability_changes << apartment_info
            done = true
          # availability and price changed... so just notify on price diff
          when has_same_unit_number
            price_changes << apartment_info
            done = true
          when is_last
            new_apartments << apartment_info
          else
            nil
        end
      end
    end

    removed_apartments = old_apartments_info - apartments_info
    
    # get email template
    email_template = File.open('./templates/email.erb').read
    
    # pass argumetns to template and get HTML
    html_email = ERB.new(email_template).result_with_hash({
      new_apartments: new_apartments,
      price_changes: price_changes,
      availability_changes: availability_changes,
      no_changes: no_changes,
      removed_apartments: removed_apartments,
    })
    
    subject = 'Apartment Updates'
    from = SendGrid::Email.new(email: ENV['EMAIL_FROM'])
    to = SendGrid::Email.new(email: ENV['EMAIL_TO'])
    content = SendGrid::Content.new(
      type: 'text/html',
      value: html_email
    )
    mail = SendGrid::Mail.new(from, subject, to, content)
    
    sg = SendGrid::API.new(api_key: ENV['SENDGRID_API_KEY'])
    # send email
    response = sg.client.mail._('send').post(request_body: mail.to_json)
    if /^2/.match(response.status_code)
      puts "\nSuccessfully sent email\n"
    else 
      puts"\nFailed to send email\n"
    end

    # upload most recent apartment data
    s3.put_object({
      bucket: 'apartment-scraper',
      key: 'apartments.json',
      content_type: 'application/json',
      body: apartments_info.to_json
    })
  end
end
