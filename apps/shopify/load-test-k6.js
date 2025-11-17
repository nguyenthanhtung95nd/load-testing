import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate } from 'k6/metrics';

// ============================================
// CUSTOM METRICS
// ============================================
// Track business-specific metrics for better insights
const ordersCreated = new Counter('orders_created');
const ordersWithSpecialProducts = new Counter('orders_with_special_products');
const orderCreationErrors = new Rate('order_creation_errors');

// ============================================
// CONFIGURATION
// ============================================
const SHOPIFY_URL = __ENV.SHOPIFY_URL || 'your-store.myshopify.com';
const SHOPIFY_TOKEN = __ENV.SHOPIFY_TOKEN || 'shpat_xxxxx';
const API_VERSION = '2024-10';

// Select scenario: 'quick', 'normal', 'peak'
const SCENARIO = __ENV.SCENARIO || 'normal';

// Special SKUs rate (% of orders that should include special SKUs like gift cards)
// Example: 0.01 = 1%, 0.05 = 5%, 0.10 = 10%
const SPECIAL_SKUS_RATE = parseFloat(__ENV.SPECIAL_SKUS_RATE || '0.01');

// ============================================
// PRODUCT SKU POOLS
// ============================================

// Normal products (physical items requiring shipping)
const NORMAL_SKUS = [
  'gid://shopify/ProductVariant/test-variant-1',
  // add more data here
];

// Special products
const SPECIAL_SKUS = [
  'gid://shopify/ProductVariant/test-variant-2',
  // add more data here
];

// ============================================
// SCENARIO DEFINITIONS
// ============================================

const SCENARIOS = {
  // Quick verification test (2 orders in 5 minutes)
  quick: {
    executor: 'shared-iterations',
    iterations: 2,
    vus: 1,                     // 2 / 100 = 1 VU
    maxDuration: '5m',          // 5 minutes
  },
  
  // Normal daily load (500 orders over 1 hour)
  normal: {
    executor: 'shared-iterations',
    iterations: 500,
    vus: 5,                     // 500 / 100 = 5 VUs
    maxDuration: '1h',          // 60 minutes
  },
  
  // Peak hour load (1000 orders over 30 minutes)
  peak: {
    executor: 'shared-iterations',
    iterations: 1000,
    vus: 10,                    // 1000 / 100 = 10 VUs
    maxDuration: '30m',         // 30 minutes
  },
};

// ============================================
// SLEEP CONFIGURATION
// ============================================
// Sleep = (Duration / Orders per VU) - 5s
//
// quick:     (300s / 2) - 5s = 145s
// normal:    (3600s / 100) - 5s = 31s
// peak:      (1800s / 100) - 5s = 13s
// ============================================

const SCENARIO_SLEEP = {
  quick: 145,
  normal: 31,
  peak: 13,
};

// ============================================
// SELECT SCENARIO
// ============================================
const selectedScenario = SCENARIOS[SCENARIO];

if (!selectedScenario) {
  throw new Error(`Unknown scenario: ${SCENARIO}. Available: ${Object.keys(SCENARIOS).join(', ')}`);
}

// ============================================
// K6 OPTIONS
// ============================================
// NOTE: When running on AWS DLT, these settings are OVERRIDDEN by DLT Console:
// - Task Count (DLT) controls number of containers
// - Concurrency (DLT) controls VUs per container
// - Ramp Up (DLT) controls ramp-up time
// - Hold For (DLT) controls test duration
//
// These settings only apply when running locally: k6 run script.js
export const options = {
  scenarios: {
    [SCENARIO]: selectedScenario,
  },
  
  thresholds: {
    'http_req_duration': ['p(95)<5000'],  // 95% of requests under 5s
    'http_req_failed': ['rate<0.1'],      // Less than 10% failures
    'checks': ['rate>0.9'],               // More than 90% checks pass
  },
  
  discardResponseBodies: false,
};

// ============================================
// GRAPHQL MUTATION
// ============================================
const ORDER_CREATE_MUTATION = `
  mutation orderCreate($order: OrderCreateOrderInput!) {
    orderCreate(order: $order) {
      order {
        id
        name
        totalPriceSet {
          shopMoney {
            amount
            currencyCode
          }
        }
        lineItems(first: 10) {
          nodes {
            id
            title
            quantity
            requiresShipping
          }
        }
      }
      userErrors {
        field
        message
      }
    }
  }
`;

// ============================================
// HELPER FUNCTIONS
// ============================================

function getRandomSixDigits() {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

function generateOrderName() {
  return `LOADTEST_${getRandomSixDigits()}`;
}

/**
 * Pick random item from array
 */
function getRandomItem(array) {
  return array[Math.floor(Math.random() * array.length)];
}

/**
 * Pick multiple random items from array (without duplicates)
 * @param {Array} array - Source array
 * @param {number} count - Number of items to pick
 * @returns {Array} - Random items
 */
function getRandomItems(array, count) {
  const shuffled = [...array].sort(() => 0.5 - Math.random());
  return shuffled.slice(0, Math.min(count, array.length));
}

/**
 * Generate random email address
 * @returns {string} Random email
 */
function generateRandomEmail() {
  const randomId = Math.floor(Math.random() * 1000000);
  return `loadtest-${randomId}@example.com`;
}

/**
 * Generate random first name
 * @returns {string} Random first name
 */
function generateRandomFirstName() {
  const firstNames = ['John', 'Jane', 'Alex', 'Sam', 'Chris', 'Taylor', 'Jordan', 'Morgan'];
  return getRandomItem(firstNames);
}

/**
 * Generate random last name
 * @returns {string} Random last name
 */
function generateRandomLastName() {
  const lastNames = ['Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 'Davis'];
  return getRandomItem(lastNames);
}

/**
 * Generate random phone number
 * @returns {string} Random phone number
 */
function generateRandomPhone() {
  const areaCode = Math.floor(Math.random() * 900) + 100; // 100-999
  const exchange = Math.floor(Math.random() * 900) + 100; // 100-999
  const number = Math.floor(Math.random() * 9000) + 1000; // 1000-9999
  return `${areaCode}${exchange}${number}`;
}

/**
 * Generate random address
 * @returns {Object} Random address object
 */
function generateRandomAddress() {
  const streetNumbers = [10, 20, 30, 40, 50, 100, 200, 300];
  const streetNames = ['Main St', 'Oak Ave', 'Park Blvd', 'Elm St', 'Maple Dr', 'Cedar Ln', 'Pine Rd', 'First St'];
  const cities = ['Springfield', 'Riverside', 'Franklin', 'Greenville', 'Madison', 'Georgetown', 'Clinton', 'Salem'];
  const provinces = ['State', 'Province', 'Region'];
  const zips = ['10001', '20002', '30003', '40004', '50005'];
  
  return {
    address1: `${getRandomItem(streetNumbers)} ${getRandomItem(streetNames)}`,
    address2: null,
    city: getRandomItem(cities),
    province: getRandomItem(provinces),
    country: 'US',
    zip: getRandomItem(zips),
    countryCode: 'US'
  };
}

/**
 * Generate line items for order
 * - Random 1-3 normal SKUs (physical products)
 * - Based on SPECIAL_SKUS_RATE, may include 1-2 special SKUs (gift cards)
 * 
 * @returns {Object} { lineItems: Array, hasSpecialProducts: Boolean }
 */
function generateLineItems() {
  const lineItems = [];
  let hasSpecialProducts = false;
  
  // Add 1-3 random normal products
  const normalCount = Math.floor(Math.random() * 3) + 1; // 1, 2, or 3
  const selectedNormalSkus = getRandomItems(NORMAL_SKUS, normalCount);
  
  selectedNormalSkus.forEach(variantId => {
    lineItems.push({
      variantId: variantId,
      quantity: 1,
      requiresShipping: true
    });
  });
  
  // Based on SPECIAL_SKUS_RATE, add special products (gift cards)
  // Example: SPECIAL_SKUS_RATE = 0.01 means 1% of orders will have gift cards
  if (Math.random() < SPECIAL_SKUS_RATE) {
    hasSpecialProducts = true;
    
    // Add 1-2 special SKUs
    const specialCount = Math.floor(Math.random() * 2) + 1; // 1 or 2
    const selectedSpecialSkus = getRandomItems(SPECIAL_SKUS, specialCount);
    
    selectedSpecialSkus.forEach(variantId => {
      lineItems.push({
        variantId: variantId,
        quantity: 1,
        requiresShipping: false
      });
    });
  }
  
  return { lineItems, hasSpecialProducts };
}

function createOrderVariables(orderName) {
  // Generate line items with metadata
  const { lineItems, hasSpecialProducts } = generateLineItems();
  
  // Generate random customer data
  const firstName = generateRandomFirstName();
  const lastName = generateRandomLastName();
  const email = generateRandomEmail();
  const phone = generateRandomPhone();
  const address = generateRandomAddress();
  
  return {
    order: {
      currency: "USD",
      presentmentCurrency: "USD",
      buyerAcceptsMarketing: false,
      email: email,
      name: orderName,
      note: "",
      phone: phone,
      poNumber: null,
      sourceIdentifier: null,
      taxesIncluded: true,
      test: false,
      financialStatus: "PAID",
      tags: [],
      
      customAttributes: [
        {
          key: "paymentMethods",
          value: "manual"
        }
      ],
      
      customer: null,
      
      billingAddress: {
        firstName: firstName,
        lastName: lastName,
        address1: address.address1,
        address2: address.address2,
        city: address.city,
        province: address.province,
        country: address.country,
        zip: address.zip,
        phone: phone,
        countryCode: address.countryCode
      },
      
      shippingAddress: {
        firstName: firstName,
        lastName: lastName,
        address1: address.address1,
        address2: address.address2,
        city: address.city,
        province: address.province,
        country: address.country,
        zip: address.zip,
        phone: phone,
        countryCode: address.countryCode
      },
      
      // Random line items (1-3 normal products + maybe special products)
      lineItems: lineItems,
      
      shippingLines: [
        {
          title: "Standard Shipping",
          code: "standard",
          source: "shopify",
          priceSet: {
            shopMoney: {
              amount: 10.00,
              currencyCode: "USD"
            }
          },
          taxLines: [
            {
              title: "Tax",
              rate: 0.08,
              channelLiable: false,
              priceSet: {
                shopMoney: {
                  amount: 0.80,
                  currencyCode: "USD"
                }
              }
            }
          ]
        }
      ],
      
      discountCode: null,
      
      transactions: [
        {
          kind: "SALE",
          status: "SUCCESS",
          gateway: "manual",
          test: false,
          amountSet: {
            shopMoney: {
              amount: 100.00,
              currencyCode: "USD"
            }
          }
        }
      ]
    },
    // Return metadata for metrics tracking
    metadata: {
      hasSpecialProducts: hasSpecialProducts,
    }
  };
}

// ============================================
// MAIN TEST FUNCTION
// ============================================
export default function() {
  const orderName = generateOrderName();
  
  // Setup request
  const url = `https://${SHOPIFY_URL}/admin/api/${API_VERSION}/graphql.json`;
  
  const orderVariables = createOrderVariables(orderName);
  const payload = JSON.stringify({
    query: ORDER_CREATE_MUTATION,
    variables: {
      order: orderVariables.order
    }
  });
  
  const params = {
    headers: {
      'Content-Type': 'application/json',
      'X-Shopify-Access-Token': SHOPIFY_TOKEN,
    },
    tags: {
      name: 'CreateOrder',
      scenario: SCENARIO,
      orderName: orderName,
      hasSpecialProducts: orderVariables.metadata.hasSpecialProducts,
    },
  };
  
  // Send request
  const response = http.post(url, payload, params);
  
  let orderCreated = false;
  try {
    const responseData = JSON.parse(response.body);
    const order = responseData?.data?.orderCreate?.order;
    orderCreated = response.status === 200 && order && order.id;
  } catch (e) {
    orderCreated = false;
  }
  
  const orderCheck = check(response, {
    'Order created successfully': () => orderCreated,
  });
  
  // Track custom metrics
  if (orderCreated) {
    ordersCreated.add(1);
    orderCreationErrors.add(0);
    
    if (orderVariables.metadata.hasSpecialProducts) {
      ordersWithSpecialProducts.add(1);
    }
  } else {
    orderCreationErrors.add(1);
    console.error(`[${SCENARIO}] Failed: ${orderName} - Status: ${response.status}`);
  }
  
  // Optional: Small delay between requests
  // Prevents server exhaustion and Shopify rate limits
  const sleepTime = SCENARIO_SLEEP[SCENARIO];
  if (sleepTime) {
    sleep(sleepTime);
  }
}