namespace :users do
  desc "Create a new user with an access key"
  task :create, [:name] => :environment do |t, args|
    if args[:name].blank?
      puts "Usage: rails users:create['John Doe']"
      exit 1
    end

    user = User.create!(name: args[:name])
    puts "\nUser created successfully!"
    puts "Name: #{user.name}"
    puts "Access Key: #{user.access_key}"
    puts "\nShare this access key with the user. They will need it to log in."
  end

  desc "List all users"
  task list: :environment do
    users = User.all
    if users.empty?
      puts "No users found."
    else
      puts "\nUsers:"
      users.each do |user|
        puts "  - #{user.name} (ID: #{user.id}, Created: #{user.created_at.to_date})"
      end
      puts "\nTotal: #{users.count}"
    end
  end

  desc "Delete a user by ID"
  task :delete, [:id] => :environment do |t, args|
    if args[:id].blank?
      puts "Usage: rails users:delete[1]"
      exit 1
    end

    user = User.find_by(id: args[:id])
    if user
      puts "Deleting user: #{user.name}"
      user.destroy!
      puts "User deleted successfully."
    else
      puts "User not found with ID: #{args[:id]}"
      exit 1
    end
  end
end
