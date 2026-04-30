# frozen_string_literal: true

RSpec.describe CoindcxBot::Regime::HmmRuntime do
  FakeSt = Struct.new(
    :label, :probability, :consecutive_bars, :flickering, :is_confirmed,
    :uncertainty, :vol_rank, :vol_rank_total, :state_id
  )

  let(:hmm_path) { File.join(Dir.tmpdir, "hmm_runtime_spec_#{Process.pid}.json") }
  let(:config) do
    CoindcxBot::Config.new(
      minimal_bot_config(
        pairs: %w[B-SOL_USDT B-ETH_USDT],
        regime: {
          enabled: true,
          hmm: {
            enabled: true,
            persistence_path: hmm_path,
            scope: 'per_pair',
            min_train_bars: 40,
            retrain_every_bars: 0
          }
        }
      )
    )
  end

  let(:runtime) { described_class.new(config: config, logger: nil) }

  after do
    File.delete(hmm_path) if File.file?(hmm_path)
  end

  describe '#tui_overlay' do
    it 'uses the focused pair even when only another pair has HMM state' do
      sol_st = FakeSt.new('S0', 1.0, 6, false, true, false, 2, 4, 0)
      runtime.instance_variable_get(:@mutex).synchronize do
        runtime.instance_variable_get(:@state_by_pair)['B-SOL_USDT'] = sol_st
        runtime.instance_variable_get(:@state_by_pair)['B-ETH_USDT'] = nil
      end

      h = runtime.tui_overlay('B-ETH_USDT')
      expect(h[:regime_pair]).to eq('B-ETH_USDT')
      expect(h[:status]).to eq('PIPE:WAIT')
      expect(h[:active]).to be(false)
    end

    it 'shows HMM metrics for the focused pair when its state exists' do
      eth_st = FakeSt.new('S1', 0.88, 4, false, true, false, 1, 4, 1)
      runtime.instance_variable_get(:@mutex).synchronize do
        runtime.instance_variable_get(:@state_by_pair)['B-ETH_USDT'] = eth_st
      end

      h = runtime.tui_overlay('B-ETH_USDT')
      expect(h[:regime_pair]).to eq('B-ETH_USDT')
      expect(h[:label]).to eq('S1')
      expect(h[:active]).to be(true)
      expect(h[:status]).to eq('PIPE:HMM')
    end

    it 'falls back to the first configured pair with state when focus is blank' do
      sol_st = FakeSt.new('S0', 1.0, 2, false, true, false, 2, 4, 0)
      runtime.instance_variable_get(:@mutex).synchronize do
        runtime.instance_variable_get(:@state_by_pair)['B-SOL_USDT'] = sol_st
      end

      h = runtime.tui_overlay(nil)
      expect(h[:regime_pair]).to eq('B-SOL_USDT')
      expect(h[:label]).to eq('S0')
    end
  end
end
