// Vision Lake Payment Pipeline
// Integrates Stripe, Xero, and PandaDoc for seamless payment processing

const express = require('express');
const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY);
const { XeroClient } = require('xero-node');
const pandadoc = require('pandadoc-node');
const admin = require('firebase-admin');

// Initialize Firebase
admin.initializeApp({
  credential: admin.credential.cert(JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT))
});

// Initialize Xero
const xero = new XeroClient({
  clientId: process.env.XERO_CLIENT_ID,
  clientSecret: process.env.XERO_CLIENT_SECRET,
  redirectUri: process.env.XERO_REDIRECT_URI,
  scopes: 'accounting.transactions accounting.contacts'
});

// Initialize PandaDoc
const pandaClient = new pandadoc.ClientApi(process.env.PANDADOC_API_KEY);

const app = express();
app.use(express.json());

// Payment webhook from Stripe
app.post('/webhook/stripe', async (req, res) => {
  const event = req.body;
  
  try {
    if (event.type === 'checkout.session.completed') {
      const session = event.data.object;
      
      // Get customer data from Stripe
      const customer = await stripe.customers.retrieve(session.customer);
      
      // Create invoice in Xero
      const invoice = await createXeroInvoice(customer, session.amount_total);
      
      // Generate contract in PandaDoc
      const contract = await generatePandaDocContract(customer, session.amount_total);
      
      // Store transaction in Firebase
      await storeTransaction(customer, session, invoice.InvoiceID, contract.id);
      
      console.log(`Payment processed successfully: ${session.id}`);
    }
    
    res.status(200).send({received: true});
  } catch (error) {
    console.error('Payment processing error:', error);
    res.status(500).send({error: error.message});
  }
});

// Helper functions
async function createXeroInvoice(customer, amount) {
  // Create contact if not exists
  const contacts = await xero.accountingApi.getContacts();
  let contact = contacts.body.Contacts.find(c => c.EmailAddress === customer.email);
  
  if (!contact) {
    const newContact = {
      Name: customer.name,
      EmailAddress: customer.email,
      Phones: [{
        PhoneType: 'MOBILE',
        PhoneNumber: customer.phone
      }]
    };
    
    const response = await xero.accountingApi.createContacts({
      Contacts: [newContact]
    });
    
    contact = response.body.Contacts[0];
  }
  
  // Create invoice
  const invoice = {
    Type: 'ACCREC',
    Contact: {
      ContactID: contact.ContactID
    },
    LineItems: [{
      Description: 'Vision Lake Subscription',
      Quantity: 1,
      UnitAmount: amount / 100,
      AccountCode: '200'
    }],
    Status: 'AUTHORISED',
    Date: new Date().toISOString().split('T')[0]
  };
  
  const response = await xero.accountingApi.createInvoices({
    Invoices: [invoice]
  });
  
  return response.body.Invoices[0];
}

async function generatePandaDocContract(customer, amount) {
  // Get template ID based on subscription tier
  const templateId = getTierTemplate(amount);
  
  // Create document from template
  const documentResponse = await pandaClient.documents.createFromTemplate({
    templateUuid: templateId,
    name: `Vision Lake Contract - ${customer.name}`,
    recipients: [{
      email: customer.email,
      first_name: customer.name.split(' ')[0],
      last_name: customer.name.split(' ').slice(1).join(' '),
      role: 'Client'
    }],
    tokens: [
      {name: 'client.name', value: customer.name},
      {name: 'subscription.amount', value: `$${amount / 100}`},
      {name: 'subscription.date', value: new Date().toLocaleDateString()}
    ]
  });
  
  // Send document for signature
  await pandaClient.documents.send(documentResponse.id, {
    message: 'Please review and sign your Vision Lake subscription contract',
    silent: false
  });
  
  return documentResponse;
}

function getTierTemplate(amount) {
  // Map amount to appropriate template
  if (amount <= 35000) { // $350
    return process.env.PANDADOC_TEMPLATE_BASIC;
  } else if (amount <= 1000000) { // $10,000
    return process.env.PANDADOC_TEMPLATE_PREMIUM;
  } else { // $25,000+
    return process.env.PANDADOC_TEMPLATE_ENTERPRISE;
  }
}

async function storeTransaction(customer, session, invoiceId, contractId) {
  return admin.firestore().collection('transactions').add({
    customerId: customer.id,
    customerEmail: customer.email,
    amount: session.amount_total,
    currency: session.currency,
    paymentStatus: 'completed',
    stripeSessionId: session.id,
    xeroInvoiceId: invoiceId,
    pandaDocContractId: contractId,
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
    squadronId: customer.metadata.squadronId || null,
    pcpAssigned: customer.metadata.pcpAssigned || null
  });
}

// Start server
const PORT = process.env.PORT || 8080;
app.listen(PORT, () => {
  console.log(`Payment pipeline running on port ${PORT}`);
});

module.exports = app;
