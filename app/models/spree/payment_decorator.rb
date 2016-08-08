Spree::Payment.class_eval do
  validates :amount, numericality: {
    less_than_or_equal_to: :minimum_amount,
    greater_than_or_equal_to: 0
  }, if: :validate_wallet_amount?, allow_blank: true

  validates :amount, numericality: {
    less_than_or_equal_to: :order_total_remaining
  }, unless: :wallet?, if: :amount_changed?, allow_blank: true

  validate :restrict_wallet_when_no_user

  delegate :remaining_total, :user_or_by_email, to: :order, prefix: true, allow_nil: true

  fsm = self.state_machines[:state]
  fsm.after_transition from: fsm.states.map(&:name) - [:completed], to: :completed, do: :consume_user_credits, if: :wallet?
  fsm.after_transition from: :completed, to: fsm.states.map(&:name) - [:completed], do: :release_user_credits, if: :wallet?

  def wallet?
    payment_method.is_a? Spree::PaymentMethod::Wallet
  end

  def invalidate_old_payments
    order.payments.with_state('checkout').where("id != ?", self.id).each do |payment|
      payment.invalidate! unless payment.wallet?
    end
  end

  private

    def restrict_wallet_when_no_user
      if wallet? && !order_user_or_by_email
        self.errors[:base] = Spree.t(:wallet_not_linked_to_user)
      end
    end

    def consume_user_credits
      debit_store_credits(amount, order)
    end

    def release_user_credits
      credit_store_credits(credit_allowed, order)
    end

    def debit_store_credits(amount, order)
      return if Spree::StoreCredit.find_by(creditable: order)
      Spree::Debit.create!(
        amount: amount,
        payment_mode: Spree::Debit::PAYMENT_MODE['Order Purchase'],
        reason: Spree.t(:store_debit_reason, order_number: order.number),
        user: order_user_or_by_email, balance: calculate_balance(amount),
        creditable: order
      )
    end

    def credit_store_credits(amount, order)
      return if Spree::StoreCredit.find_by(creditable: order)
      Spree::Credit.create!(
        amount: amount,
        payment_mode: Spree::Credit::PAYMENT_MODE['Payment Refund'],
        reason: Spree.t(:store_credit_reason, order_number: order.number),
        user: order_user_or_by_email, balance: calculate_balance(amount),
        creditable: order
      )
    end

    def calculate_balance(amount)
      order_user_or_by_email.store_credits_total - amount
    end

    def minimum_amount
      [order_user_or_by_email.store_credits_total.to_f, order_remaining_total.to_f].min
    end

    def validate_wallet_amount?
      order_user_or_by_email && wallet? && amount_changed?
    end

    def order_total_remaining
      order_remaining_total.to_f
    end

    def update_order
      if state == "checkout"
        return
      end

      if wallet? && !order.reload.payments.last.wallet?
        return
      end

      if completed? || void?
        order.updater.update_payment_total
      end

      if order.completed?
        order.updater.update_payment_state
        order.updater.update_shipments
        order.updater.update_shipment_state
      end

      if self.completed? || order.completed?
        order.persist_totals
      end
    end
end
