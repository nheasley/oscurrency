require 'will_paginate/array'

class Membership < ActiveRecord::Base
  extend ActivityLogger
  extend PreferencesHelper

  scope :with_role, lambda { |role| {:conditions => "roles_mask & #{2**ROLES.index(role.to_s)} > 0"} }
  scope :active, :include => :person, :conditions => {'people.deactivated' => false}
  scope :listening, :include => [:member_preference, :person], :conditions => {'people.deactivated' => false, 'member_preferences.forum_notifications' => true}
  scope :search_by, lambda { |text| {:include => :person, :conditions => ["people.name ILIKE ? OR people.business_name ILIKE ? OR people.description ILIKE ?","%#{text}%","%#{text}%","%#{text}%"]} }

  belongs_to :group
  belongs_to :person
  has_one :member_preference
  has_many :activities, :as => :item #, :dependent => :destroy

  validates_presence_of :person_id, :group_id
  after_create :create_member_preference

  # Status codes.
  ACCEPTED  = 0
  INVITED   = 1 # deprecated
  PENDING   = 2

  ROLES = %w[individual admin moderator org]

  class << self
    def custom_search(category,group,page,posts_per_page,search=nil)
      unless category
        group.memberships.active.search_by(search).paginate(:page => page,
                                                            :conditions => ['status = ?', Membership::ACCEPTED],
                                                            :order => 'memberships.created_at DESC, people.business_name ASC, people.name ASC',
                                                            :include => :person,
                                                            :per_page => posts_per_page)
      else
        category.people.all(:joins => :memberships,
                            :select => "people.*,memberships.id as categorized_membership",
                            :conditions => {:memberships => {:group_id => group.id},
                                            :people => {:deactivated => false}}
        ).map {|p| Membership.find(p.categorized_membership)}.paginate(:page => page,
                                                                       :conditions => ['status = ?', Membership::ACCEPTED],
                                                                       :order => 'memberships.created_at DESC, people.business_name ASC, people.name ASC',
                                                                       :include => :person,
                                                                       :per_page => posts_per_page)
      end
    end
  end

  def account
    group.adhoc_currency? ? person.account(group) : nil
  end

  def create_member_preference
    MemberPreference.create(:membership => self)
  end

  # Accept a membership request (instance method).
  def accept
    Membership.accept(person, group)
  end

  def breakup
    Membership.breakup(person, group)
  end

  def roles=(roles)
    self.roles_mask = (roles & ROLES).map { |r| 2**ROLES.index(r) }.sum
  end

  def add_role(new_role)
    a = self.roles
    a << new_role
    self.roles = a
  end

  def roles
    ROLES.reject do |r|
      ((roles_mask || 0) & 2**ROLES.index(r)).zero?
    end
  end

  def is?(role)
    roles.include?(role.to_s)
  end

  class << self

    # Return true if the person is member of the group.
    def exist?(person, group)
      where(:person_id => person, :group_id => group).exists?
    end

    # Make a pending membership request.
    def request(person, group, send_mail = nil)
      send_mail ||= global_prefs.email_notifications?
      unless person.groups.include?(group) or Membership.exist?(person, group)
        if group.public? or group.private?
          membership = nil
          transaction do
            membership = create(:person => person, :group => group, :status => PENDING)
            after_transaction { PersonMailerQueue.membership_request(membership) } if send_mail
          end
          if group.public?
            Membership.accept(person, group)
            after_transaction { PersonMailerQueue.membership_public_group(membership) } if send_mail
          end
        end
        true
      end
    end

    # Accept a membership request.
    def accept(person, group)
      transaction do
        accepted_at = Time.now
        accept_one_side(person, group, accepted_at)
      end
      log_activity(mem(person, group))
    end

    def breakup(person, group)
      transaction do
        destroy(mem(person, group))
      end
    end

    def mem(person, group)
      where(:person_id => person, :group_id => group).first
    end

    def accepted?(person, group)
      where(:person_id => person, :group_id => group, :status => ACCEPTED).exists?
    end

    def pending?(person, group)
      where(:person_id => person, :group_id => group, :status => PENDING).exists?
    end

    # private

    # Update the db with one side of an accepted connection request.
    def accept_one_side(person, group, accepted_at)
      mem = mem(person, group)
      mem.status = ACCEPTED
      mem.accepted_at = accepted_at
      mem.add_role('individual')
      mem.save

      if person.accounts.find(:first,:conditions => ["group_id = ?",group.id]).nil?
        account = Account.new( :name => group.name ) # group name can change
        account.balance = Account::INITIAL_BALANCE
        account.person = person
        account.group = group
        account.credit_limit = group.default_credit_limit
        account.save
      end
    end

    def log_activity(membership)
      activity = Activity.create!(:item => membership, :person => membership.person)
      add_activities(:activity => activity, :person => membership.person)
    end
  end

end
