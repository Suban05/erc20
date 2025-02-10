# frozen_string_literal: true

# Copyright (c) 2025 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'donce'
require 'eth'
require 'loog'
require 'random-port'
require 'shellwords'
require 'typhoeus'
require 'minitest/autorun'
require_relative '../../lib/erc20'
require_relative '../../lib/erc20/wallet'

# Test.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2025 Yegor Bugayenko
# License:: MIT
class TestWallet < Minitest::Test
  # At this address, in the mainnet, there are a few USDT tokens. I won't
  # move them anyway, that's why tests can use this address forever.
  STABLE_ADDRESS = '0xEB2fE8872A6f1eDb70a2632EA1f869AB131532f6'

  # One guy private hex.
  JEFF = '81a9b2114d53731ecc84b261ef6c0387dde34d5907fe7b441240cc21d61bf80a'

  # Another guy private hex.
  WALTER = '91f9111b1744d55361e632771a4e53839e9442a9fef45febc0a5c838c686a15b'

  def test_checks_balance_on_mainnet
    b = mainnet.balance(STABLE_ADDRESS)
    refute_nil(b)
    assert_equal(27_258_889, b)
  end

  def test_checks_balance_of_absent_address
    a = '0xEB2fE8872A6f1eDb70a2632Effffffffffffffff'
    b = mainnet.balance(a)
    refute_nil(b)
    assert_equal(0, b)
  end

  def test_fails_with_invalid_infura_key
    w = ERC20::Wallet.new(
      rpc: 'https://mainnet.infura.io/v3/invalid-key-here',
      log: Loog::NULL
    )
    assert_raises(StandardError) { w.balance(STABLE_ADDRESS) }
  end

  def test_checks_balance_on_testnet
    skip('does not work')
    b = testnet.balance(STABLE_ADDRESS)
    refute_nil(b)
    assert_predicate(b, :positive?)
  end

  def test_checks_balance_on_hardhat
    on_hardhat do |wallet|
      b = wallet.balance(Eth::Key.new(priv: JEFF).address.to_s)
      assert_equal(123_000_100_000, b)
    end
  end

  def test_pays_on_hardhat
    on_hardhat do |wallet|
      to = Eth::Key.new(priv: WALTER).address.to_s
      before = wallet.balance(to)
      sum = 42_000
      from = Eth::Key.new(priv: JEFF).address.to_s
      assert_operator(wallet.balance(from), :>, sum * 2)
      wallet.pay(JEFF, to, sum)
      assert_equal(before + sum, wallet.balance(to))
    end
  end

  def test_accepts_payments_on_hardhat
    on_hardhat do |wallet|
      txn = nil
      daemon =
        Thread.new do
          wallet.accept([WALTER]) do |t|
            txn = t
          end
        end
      to = Eth::Key.new(priv: WALTER).address.to_s
      sum = 77_000
      wallet.pay(JEFF, to, sum)
      daemon.join(30)
      refute_nil(txn)
      assert_equal(sum, txn[:amount])
      assert_equal(Eth::Key.new(priv: JEFF).address.to_s, txn[:from])
      assert_equal(to, txn[:address])
    end
  end

  private

  def wait_for(port)
    loop do
      break if Typhoeus::Request.get("http://localhost:#{port}").code == 200
    rescue Errno::ECONNREFUSED
      sleep(0.1)
      retry
    end
  end

  def env(var)
    key = ENV.fetch(var, nil)
    skip("The #{var} environment variable is not set") if key.nil?
    key
  end

  def mainnet
    [
      "https://mainnet.infura.io/v3/#{env('INFURA_KEY')}",
      "https://go.getblock.io/#{env('GETBLOCK_KEY')}"
    ].map do |rpc|
      ERC20::Wallet.new(rpc:, log: Loog::NULL)
    end.sample
  end

  def testnet
    [
      "https://sepolia.infura.io/v3/#{env('INFURA_KEY')}",
      "https://go.getblock.io/#{env('GETBLOCK_SEPOILA_KEY')}"
    ].map do |rpc|
      ERC20::Wallet.new(rpc:, log: Loog::NULL)
    end.sample
  end

  def on_hardhat
    RandomPort::Pool::SINGLETON.acquire do |port|
      donce(
        home: File.join(__dir__, '../../hardhat'),
        ports: { port => 8545 },
        command: 'npx hardhat node',
        log: Loog::NULL
      ) do
        wait_for(port)
        cmd = [
          '(cat hardhat.config.js)',
          '(ls -al)',
          '(echo y | npx hardhat ignition deploy ./ignition/modules/Foo.ts --network foo --deployment-id foo)',
          '(npx hardhat ignition status foo | tail -1 | cut -d" " -f3)'
        ].join(' && ')
        contract = donce(
          home: File.join(__dir__, '../../hardhat'),
          command: "/bin/bash -c #{Shellwords.escape(cmd)}",
          build_args: { 'HOST' => donce_host, 'PORT' => port },
          log: Loog::NULL,
          root: true
        ).split("\n").last
        wallet = ERC20::Wallet.new(
          contract:, chain: 4242,
          rpc: "http://localhost:#{port}",
          log: Loog::NULL
        )
        yield wallet
      end
    end
  end
end
