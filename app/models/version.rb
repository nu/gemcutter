class Version < ActiveRecord::Base

  default_scope :order => 'position'

  belongs_to :rubygem
  has_many :dependencies, :dependent => :destroy

  scope :owned_by, lambda { |user|
    { :conditions => { :rubygem_id => user.rubygem_ids } }
  }

  scope :subscribed_to_by, lambda { |user|
    { :conditions => { :rubygem_id => user.subscribed_gem_ids },
      :order => 'created_at desc' }
  }

  scope :with_associated, {
    :conditions => ["versions.rubygem_id IN (SELECT versions.rubygem_id FROM versions GROUP BY versions.rubygem_id HAVING COUNT(versions.id) > 1)"],
    :include    => :rubygem,
    :order      => "versions.built_at desc"
  }

  scope :latest,     { :conditions => { :latest       => true     }}
  scope :with_deps,  { :include    => { :dependencies => :rubygem }}
  scope :prerelease, { :conditions => { :prerelease   => true     }}
  scope :release,    { :conditions => { :prerelease   => false    }}
  scope :indexed,    { :conditions => { :indexed      => true     }}

  before_save      :update_prerelease
  after_save       :reorder_versions
  after_save       :full_nameify!
  after_validation :join_authors

  validates_format_of :number, :with => /\A#{Gem::Version::VERSION_PATTERN}\z/
  validate :platform_and_number_are_unique, :on => :create
  validate :authors_format, :on => :create

  def platform_and_number_are_unique
    if Version.exists?(:rubygem_id => rubygem_id,
                       :number     => number,
                       :platform   => platform)
      errors[:base] << "A version already exists with this number or platform."
    end
  end

  def authors_format
    if !authors.is_a?(Array) || authors.any? { |a| !a.is_a?(String) }
      errors.add :authors, "must be an Array of Strings"
    end
  end

  def join_authors
    self.authors = self.authors.join(', ') if self.authors.is_a?(Array)
  end

  def self.with_indexed(reverse = false)
    order =  "rubygems.name asc"
    order << ", position desc" if reverse

    all :conditions => {:indexed => true},
        :include    => :rubygem,
        :order      => order
  end

  def self.most_recent
    recent = where(:latest => true)
    recent.find_by_platform('ruby') || recent.first || first
  end

  def self.updated(limit=5)
    where("built_at <= ?", DateTime.now.utc).with_associated.limit(limit)
  end

  def self.published(limit=5)
    where("built_at <= ?", DateTime.now.utc).order("built_at desc").limit(limit)
  end

  def self.find_from_slug!(rubygem_id, slug)
    rubygem = Rubygem.find(rubygem_id)
    find_by_full_name!("#{rubygem.name}-#{slug}")
  end

  def self.platforms
    select('platform').map(&:platform).uniq
  end

  def platformed?
    platform != "ruby"
  end

  def update_prerelease
    self[:prerelease] = to_gem_version.prerelease?
    true
  end

  def reorder_versions
    rubygem.reorder_versions
  end

  def yank!
    update_attributes!(:indexed => false)
  end
  
  def unyank!
    update_attributes!(:indexed => true)
  end

  def yanked?
    !indexed
  end

  def info
    [ description, summary, "This rubygem does not have a description or summary." ].detect(&:present?)
  end

  def update_attributes_from_gem_specification!(spec)
    self.update_attributes!(
      :authors           => spec.authors,
      :description       => spec.description,
      :summary           => spec.summary,
      :built_at          => spec.date,
      :indexed           => true
    )
  end

  def platform_as_number
    case self.platform
      when 'ruby' then 1
      else             0
    end
  end

  def <=>(other)
    self_version  = self.to_gem_version
    other_version = other.to_gem_version

    if self_version == other_version
      self.platform_as_number <=> other.platform_as_number
    else
      self_version <=> other_version
    end
  end

  def built_at_date
    built_at.to_date.to_formatted_s(:long)
  end

  def full_nameify!
    self.full_name = "#{rubygem.name}-#{number}"
    self.full_name << "-#{platform}" if platformed?

    Version.update_all({:full_name => full_name}, {:id => id})
  end

  def slug
    full_name.gsub(/^#{rubygem.name}-/, '')
  end

  def downloads_count
    Download.for(self)
  end

  def to_s
    number
  end

  def to_title
    "#{rubygem.name} (#{to_s})"
  end

  def to_gem_version
    Gem::Version.new(number)
  end

  def to_index
    [rubygem.name, to_gem_version, platform]
  end

  def to_install
    command = "gem install #{rubygem.name}"
    latest = prerelease ? rubygem.versions.prerelease.first : rubygem.versions.most_recent
    command << " -v #{number}" if latest != self
    command << " --pre" if prerelease
    command
  end

  def to_spec
    Gem::Specification.new do |spec|
      spec.name        = rubygem.name
      spec.version     = to_gem_version
      spec.authors     = authors.split(', ')
      spec.date        = built_at
      spec.description = description
      spec.summary     = summary

      dependencies.each do |dep|
        spec.add_dependency(dep.rubygem.name, dep.requirements.split(', '))
      end
    end
  end
end
