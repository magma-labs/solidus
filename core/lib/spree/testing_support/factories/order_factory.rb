require 'spree/testing_support/factories/address_factory'
require 'spree/testing_support/factories/shipment_factory'
require 'spree/testing_support/factories/store_factory'
require 'spree/testing_support/factories/user_factory'
require 'spree/testing_support/factories/line_item_factory'
require 'spree/testing_support/factories/payment_factory'

FactoryGirl.define do
  factory :order, class: Spree::Order do
    user
    bill_address
    ship_address
    completed_at nil
    email { user.try(:email) }
    store

    transient do
      line_items_price BigDecimal.new(10)
    end

    factory :order_with_totals do
      after(:create) do |order, evaluator|
        create(:line_item, order: order, price: evaluator.line_items_price)
        order.line_items.reload # to ensure order.line_items is accessible after
      end
    end

    factory :order_with_line_items do
      bill_address
      ship_address

      transient do
        line_items_count 1
        line_items_attributes { [{}] * line_items_count }
        shipment_cost 100
        shipping_method nil
        stock_location { create(:stock_location) }
      end

      after(:create) do |order, evaluator|
        evaluator.stock_location # must evaluate before creating line items

        evaluator.line_items_attributes.each do |attributes|
          attributes = {order: order, price: evaluator.line_items_price}.merge(attributes)
          create(:line_item, attributes)
        end
        order.line_items.reload

        create(:shipment, order: order, cost: evaluator.shipment_cost, shipping_method: evaluator.shipping_method, address: evaluator.ship_address, stock_location: evaluator.stock_location)
        order.shipments.reload

        order.update!
      end

      factory :completed_order_with_totals do
        state 'complete'

        after(:create) do |order|
          order.refresh_shipment_rates
          order.update_column(:completed_at, Time.current)
        end

        factory :completed_order_with_pending_payment do
          after(:create) do |order|
            create(:payment, amount: order.total, order: order, state: 'pending')
          end
        end

        factory :order_ready_to_ship do
          payment_state 'paid'
          shipment_state 'ready'

          transient do
            payment_type :credit_card_payment
          end

          after(:create) do |order, evaluator|
            create(evaluator.payment_type, amount: order.total, order: order, state: 'completed')
            order.shipments.each do |shipment|
              shipment.inventory_units.update_all state: 'on_hand'
              shipment.update_column('state', 'ready')
            end
            order.reload
          end

          factory :shipped_order do
            transient do
              with_cartons true
            end
            after(:create) do |order, evaluator|
              order.shipments.each do |shipment|
                shipment.inventory_units.update_all state: 'shipped'
                shipment.update_columns(state: 'shipped', shipped_at: Time.current)
                if evaluator.with_cartons
                  Spree::Carton.create!(
                    stock_location: shipment.stock_location,
                    address: shipment.address,
                    shipping_method: shipment.shipping_method,
                    inventory_units: shipment.inventory_units,
                    shipped_at: Time.current,
                  )
                end
              end
              order.reload
            end
          end
        end
      end
    end
  end

  factory :completed_order_with_promotion, parent: :completed_order_with_totals, class: "Spree::Order" do
    transient do
      promotion nil
      promotion_code nil
    end

    after(:create) do |order, evaluator|
      promotion = evaluator.promotion || create(:promotion, code: "test")
      promotion_code = evaluator.promotion_code || promotion.codes.first

      promotion.actions.each do |action|
        action.perform({order: order, promotion: promotion, promotion_code: promotion_code})
      end
    end
  end
end
