# frozen_string_literal: true

require 'bigdecimal'
require 'set'

module CoindcxBot
  module Tui
    # Normalizes CoinDCX futures `list_positions` / wallet payloads for TUI mirroring (live observe).
    module LiveAccountMirror
      module_function

      def futures_pair_key(s)
        s.to_s.strip.upcase.sub(/\AB-/, '').tr('-', '_')
      end

      def normalize_bot_pair(row)
        raw = (row[:pair] || row[:instrument] || row[:instrument_name] ||
                row['pair'] || row['instrument'] || row['instrument_name']).to_s.strip
        return '' if raw.empty?

        k = futures_pair_key(raw)
        return '' if k.empty?

        "B-#{k}"
      end

      def row_open?(row)
        ap = row[:active_pos] || row['active_pos']
        bd = BigDecimal(ap.to_s)
        !bd.abs.zero?
      rescue ArgumentError, TypeError
        qty = row[:quantity] || row['quantity']
        q = BigDecimal(qty.to_s)
        !q.zero?
      rescue ArgumentError, TypeError
        false
      end

      def unrealized_usdt_from_row(row)
        raw = row[:unrealized_pnl] || row[:unrealised_pnl] || row[:unrealized_pnl_usdt] ||
              row[:pnl] || row[:unrealizedPnl] ||
              row['unrealized_pnl'] || row['unrealised_pnl'] || row['unrealized_pnl_usdt'] ||
              row['pnl'] || row['unrealizedPnl']
        return nil if raw.nil? || raw.to_s.strip.empty?

        BigDecimal(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def realized_usdt_from_row(row)
        r = row.is_a?(Hash) ? row.transform_keys(&:to_sym) : {}
        raw = r[:realized_pnl_session] || r[:realised_pnl_session] || r[:session_realized_pnl] ||
              r[:realized_pnl] || r[:realizedPnl] || r[:total_realized_pnl] ||
              r['realized_pnl_session'] || r['realised_pnl_session'] || r['session_realized_pnl'] ||
              r['realized_pnl'] || r['realizedPnl'] || r['total_realized_pnl']
        return BigDecimal('0') if raw.nil? || raw.to_s.strip.empty?

        BigDecimal(raw.to_s)
      rescue ArgumentError, TypeError
        BigDecimal('0')
      end

      # Session / row **realized** in USDT (exchange field names vary). Open rows only — same scope as uPnL sums.
      def sum_realized_usdt(rows)
        Array(rows).sum(BigDecimal('0')) do |r|
          next BigDecimal('0') unless row_open?(r)

          realized_usdt_from_row(r)
        end
      end

      # Sums exchange-reported uPnL when present; otherwise marks each open row to market using +ticks_by_pair+
      # (+{ "B-SOL_USDT" => { price: bd } }+ / engine tick shape).
      def sum_unrealized_usdt(rows, ticks_by_pair = nil)
        Array(rows).sum(BigDecimal('0')) do |r|
          u = unrealized_usdt_from_row(r)
          next u unless u.nil?

          next BigDecimal('0') unless ticks_by_pair && row_open?(r)

          pseudo = pseudo_journal_from_exchange(r)
          next BigDecimal('0') unless pseudo

          pair = pseudo[:pair].to_s
          tick = ticks_by_pair[pair]
          px_raw =
            if tick.is_a?(Hash)
              tick[:mark] || tick['mark'] || tick[:price] || tick['price']
            else
              nil
            end
          next BigDecimal('0') if px_raw.nil? || px_raw.to_s.strip.empty?

          calc = CoindcxBot::Strategy::UnrealizedPnl.position_usdt(pseudo, BigDecimal(px_raw.to_s))
          calc.nil? ? BigDecimal('0') : calc
        end
      end

      def open_position_count(rows)
        Array(rows).count { |r| row_open?(r) }
      end

      # Live exchange mirror: **NET / DD** use **exchange USDT only** — (+realized_usdt + unrealized_usdt+) × FX when
      # +realized_usdt+ is present in +live_tui_metrics+ (summed from open position rows). Avoids mixing the SQLite
      # journal (paper/live bookkeeping) with live account MTM. Legacy: if +realized_usdt+ is absent, falls back to
      # journal today + unreal × FX.
      def combined_daily_pnl_inr_for_header(snap, inr_per_usdt)
        base = snap.daily_pnl
        return base if snap.dry_run

        m = snap.live_tui_metrics
        return base unless m.is_a?(Hash) && m.key?(:unrealized_usdt)

        unreal = BigDecimal((m[:unrealized_usdt] || 0).to_s)
        fx = BigDecimal(inr_per_usdt.to_s)
        if m.key?(:realized_usdt)
          realized = BigDecimal((m[:realized_usdt] || 0).to_s)
          return (realized + unreal) * fx
        end

        base + (unreal * fx)
      rescue ArgumentError, TypeError
        base
      end

      # Copies margin fields from the exchange row onto the pseudo-journal hash so the TUI can show ROE% vs margin.
      def passthrough_margin_keys(row, target)
        keys = %i[
          isolated_margin initial_margin margin used_margin order_margin position_margin
          locked_margin maintenance_margin im mm
        ]
        keys.each do |k|
          next unless row.key?(k) || row.key?(k.to_s)

          v = row[k] || row[k.to_s]
          target[k] = v unless v.nil?
        end
      end

      def open_on_configured_pairs(rows, configured_pairs)
        want = configured_pairs.map { |p| futures_pair_key(p) }.to_set
        Array(rows).count do |r|
          next false unless row_open?(r)

          want.include?(futures_pair_key(normalize_bot_pair(r)))
        end
      end

      # Builds a journal-shaped row for {DeskViewModel#execution_row_for} / unrealized helpers.
      def pseudo_journal_from_exchange(row)
        pair = normalize_bot_pair(row)
        return nil if pair.empty?

        ap = row[:active_pos] || row['active_pos']
        qty =
          if ap && !ap.to_s.strip.empty?
            BigDecimal(ap.to_s).abs
          else
            BigDecimal((row[:quantity] || row['quantity'] || 0).to_s).abs
          end
        return nil if qty.zero?

        side =
          if ap && !ap.to_s.strip.empty?
            BigDecimal(ap.to_s).positive? ? 'long' : 'short'
          else
            s = (row[:side] || row['side']).to_s.downcase
            %w[long buy].include?(s) ? 'long' : 'short'
          end

        # CoinDCX list response uses +avg_price+ (see API docs); keep other aliases for compatibility.
        entry_raw = row[:avg_price] || row[:average_entry_price] || row[:avg_entry_price] || row[:entry_price] ||
                    row['avg_price'] || row['average_entry_price'] || row['avg_entry_price'] || row['entry_price']
        entry = entry_raw.nil? || entry_raw.to_s.strip.empty? ? nil : BigDecimal(entry_raw.to_s)
        entry = nil if entry&.zero?

        h = {
          pair: pair,
          side: side,
          quantity: qty.to_s('F'),
          entry_price: entry&.to_s('F'),
          stop_price: nil,
          trail_price: nil,
          exchange_mirror: true
        }
        passthrough_margin_keys(row, h)
        u = unrealized_usdt_from_row(row)
        h[:exchange_unrealized_usdt] = u.to_s('F') unless u.nil?
        h
      rescue ArgumentError, TypeError
        nil
      end

      # Picks the futures wallet hash row for +margin_currency_short_name+ (from bot.yml), with optional
      # +strict+ mode (+strict: true+ → only a row whose currency exactly matches +want+, no INR/USDT fallback).
      # CoinDCX / JSON may use snake_case symbols or camelCase strings; never use +available_balance+ here.
      WALLET_BALANCE_FIELD_KEYS = [
        :balance, :wallet_balance, :total_balance, :total_wallet_balance, :account_balance,
        :net_balance, :margin_balance, :spot_futures_wallet_balance,
        'balance', 'walletBalance', 'wallet_balance', 'totalBalance', 'total_balance',
        'accountBalance', 'netBalance', 'marginBalance'
      ].freeze

      def select_wallet_row(payload, margin_currency_short_name, strict: false, cached_rows: nil)
        want = margin_currency_short_name.to_s.strip.upcase
        want = 'USDT' if want.empty?

        rows = cached_rows || extract_wallet_rows(payload)
        if rows.empty? && payload.is_a?(Hash)
          h = payload.transform_keys(&:to_sym)
          c = wallet_row_currency(h)
          rows = [h] if %w[USDT INR].include?(c)
        end
        return nil if rows.empty?

        hit = rows.find { |r| wallet_row_currency(r) == want }
        if strict
          return hit.is_a?(Hash) ? hit : nil
        end

        hit ||= rows.find { |r| wallet_row_currency(r) == 'INR' }
        hit ||= rows.find { |r| wallet_row_currency(r) == 'USDT' }
        hit ||= rows.first
        hit.is_a?(Hash) ? hit : nil
      end

      def parse_wallet_decimal(row, *keys)
        keys.flatten.each do |k|
          raw =
            case k
            when Symbol
              row[k] || row[k.to_s]
            else
              row[k] || row[k.to_sym]
            end
          next if raw.nil? || raw.to_s.strip.empty?

          return BigDecimal(raw.to_s)
        rescue ArgumentError, TypeError
          next
        end
        nil
      end

      # Full numeric snapshot for the selected margin-currency row (balance, optional available / locked / cross).
      # +:balance+ is **wallet balance** (deposits + realized, excluding unrealized), never +available_balance+ alone
      # (that is free margin and was a common mis-parse when +balance+ was omitted on the INR row).
      # When the selected row has no balance fields but another wallet row does (e.g. USDT row carries balance while
      # INR row carries margin breakdown), pass +inr_per_usdt+ to synthesize the missing side.
      #
      # Keys: +:currency+, +:balance+, optional +:available_balance+, +:locked_balance+, +:cross_order_margin+,
      # +:cross_user_margin+.
      def extract_wallet_snapshot_for_display(payload, margin_currency_short_name, inr_per_usdt: nil)
        rows = extract_wallet_rows(payload)
        row = select_wallet_row(payload, margin_currency_short_name, strict: false, cached_rows: rows)
        return nil unless row

        cur = wallet_row_currency(row)
        cur = 'USDT' unless %w[INR USDT].include?(cur)

        bal = parse_wallet_decimal(row, *WALLET_BALANCE_FIELD_KEYS)
        bal ||= wallet_balance_from_sibling_row(rows, cur, inr_per_usdt)
        return nil if bal.nil?

        avail = parse_wallet_decimal(row, :available_balance, :available, :free_balance, :free)
        locked = parse_wallet_decimal(row, :locked_balance, :locked, :locked_margin)
        xo = parse_wallet_decimal(row, :cross_order_margin, :crossOrderMargin)
        xu = parse_wallet_decimal(row, :cross_user_margin, :crossUserMargin)

        h = { currency: cur, balance: bal }
        h[:available_balance] = avail unless avail.nil?
        h[:locked_balance] = locked unless locked.nil?
        h[:cross_order_margin] = xo unless xo.nil?
        h[:cross_user_margin] = xu unless xu.nil?
        h
      end

      # Returns +{ amount: BigDecimal, currency: 'INR'|'USDT' }+ for the futures wallet row matching
      # +margin_currency_short_name+ (from bot.yml). INR rows are shown as-is in the TUI; USDT is converted via FX.
      def extract_wallet_balance_for_display(payload, margin_currency_short_name, inr_per_usdt: nil)
        snap = extract_wallet_snapshot_for_display(payload, margin_currency_short_name, inr_per_usdt: inr_per_usdt)
        return nil unless snap

        { amount: snap[:balance], currency: snap[:currency] }
      end

      # @deprecated Use +extract_wallet_balance_for_display+; kept for callers that only need USDT.
      def extract_wallet_usdt_balance(payload)
        usdt = select_wallet_row(payload, 'USDT', strict: true)
        return nil unless usdt.is_a?(Hash)
        return nil unless wallet_row_currency(usdt) == 'USDT'

        raw = balance_raw_from_wallet_row(usdt)
        return nil if raw.nil? || raw.to_s.strip.empty?

        BigDecimal(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def wallet_row_currency(r)
        (r[:currency_short_name] || r[:currency] || r['currency_short_name'] || r['currency']).to_s.upcase
      end

      def balance_raw_from_wallet_row(row)
        row[:balance] || row[:wallet_balance] || row[:total_balance] ||
          row['balance'] || row['wallet_balance'] || row['total_balance']
      end

      def wallet_balance_from_sibling_row(rows, target_currency, inr_per_usdt)
        return nil if rows.nil? || rows.empty? || inr_per_usdt.nil?

        fx = BigDecimal(inr_per_usdt.to_s)
        return nil unless fx.positive?

        case target_currency.to_s.upcase
        when 'INR'
          usdt_row = rows.find { |r| wallet_row_currency(r) == 'USDT' }
          return nil unless usdt_row

          usdt_amt = parse_wallet_decimal(usdt_row, *WALLET_BALANCE_FIELD_KEYS)
          return nil if usdt_amt.nil?

          usdt_amt * fx
        when 'USDT'
          inr_row = rows.find { |r| wallet_row_currency(r) == 'INR' }
          return nil unless inr_row

          inr_amt = parse_wallet_decimal(inr_row, *WALLET_BALANCE_FIELD_KEYS)
          return nil if inr_amt.nil?

          inr_amt / fx
        else
          nil
        end
      rescue ArgumentError, TypeError
        nil
      end

      def extract_wallet_rows(payload)
        return [] if payload.nil?

        # GET /derivatives/futures/wallets returns a JSON array of per-currency rows (see CoinDCX API docs).
        return normalize_wallet_row_array(payload) if payload.is_a?(Array)

        h = payload.is_a?(Hash) ? payload.transform_keys(&:to_sym) : {}
        inner = h[:data] if h[:data].is_a?(Hash) || h[:data].is_a?(Array)
        inner ||= h
        inner = inner.transform_keys(&:to_sym) if inner.is_a?(Hash)
        if inner.is_a?(Hash)
          w = inner[:wallets] || inner[:wallet] || inner[:balances] || inner[:positions]
          return normalize_wallet_row_array(w) if w.is_a?(Array)
        end
        return normalize_wallet_row_array(inner) if inner.is_a?(Array)

        []
      end

      def normalize_wallet_row_array(arr)
        Array(arr).map { |el| el.is_a?(Hash) ? el.transform_keys(&:to_sym) : {} }
      end
    end
  end
end
