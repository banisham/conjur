require 'spec_helper'

describe Role, :type => :model do
  include_context "create user"

  let(:login) { "u-#{SecureRandom.uuid}" }

  shared_examples_for "provides expected JSON" do
    specify {
      the_user.reload
      hash = JSON.parse(the_user.to_json)
      expect(hash.delete("created_at")).to be
      expect(hash).to eq(as_json.stringify_keys)
    }
  end

  let(:base_hash) {
    {
      id: the_user.role_id
    }
  }

  context "basic object" do
    let(:as_json) { base_hash }
    it_should_behave_like "provides expected JSON"
  end
end